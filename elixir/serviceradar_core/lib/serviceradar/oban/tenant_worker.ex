defmodule ServiceRadar.Oban.TenantWorker do
  @moduledoc """
  Behaviour for tenant-aware Oban workers.

  Extends Oban.Worker with tenant isolation:
  - Jobs are automatically routed to tenant-specific queues
  - Worker receives tenant context in perform/2
  - Tenant validation before job execution

  ## Usage

      defmodule MyApp.Workers.SyncWorker do
        use ServiceRadar.Oban.TenantWorker,
          queue_type: :integrations,
          max_attempts: 5

        @impl true
        def perform_for_tenant(args, tenant_id, job) do
          # Your job logic here
          # tenant_id is guaranteed to be valid
          :ok
        end
      end

  ## Enqueueing Jobs

      # Use the worker's enqueue function
      SyncWorker.enqueue(tenant_id, %{source_id: "123"})

      # Or use TenantQueues directly
      TenantQueues.insert_job(tenant_id, SyncWorker, %{source_id: "123"})

  ## Options

    - `:queue_type` - Queue type atom (default: :default)
    - `:max_attempts` - Maximum retry attempts (default: 3)
    - `:priority` - Default job priority (default: 0)
    - `:unique` - Oban unique job options (optional)

  ## Callbacks

    - `perform_for_tenant/3` - Required. Called with (args, tenant_id, job)
    - `on_success/3` - Optional. Called after successful execution
    - `on_failure/4` - Optional. Called after failed execution
  """

  @doc """
  Callback for tenant-aware job execution.

  Receives the job args, tenant_id, and full Oban.Job struct.
  Must return `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @callback perform_for_tenant(args :: map(), tenant_id :: String.t(), job :: Oban.Job.t()) ::
              :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}

  @doc """
  Optional callback after successful job execution.
  """
  @callback on_success(args :: map(), tenant_id :: String.t(), result :: term()) :: :ok

  @doc """
  Optional callback after failed job execution.
  """
  @callback on_failure(args :: map(), tenant_id :: String.t(), error :: term(), job :: Oban.Job.t()) ::
              :ok

  @optional_callbacks [on_success: 3, on_failure: 4]

  defmacro __using__(opts) do
    queue_type = Keyword.get(opts, :queue_type, :default)
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    priority = Keyword.get(opts, :priority, 0)
    unique = Keyword.get(opts, :unique)

    quote do
      @behaviour ServiceRadar.Oban.TenantWorker

      use Oban.Worker,
        max_attempts: unquote(max_attempts),
        priority: unquote(priority),
        unique: unquote(unique)

      require Logger

      alias ServiceRadar.Oban.TenantQueues

      @queue_type unquote(queue_type)

      @doc """
      Enqueues a job for a specific tenant.

      The job will be routed to the tenant's queue automatically.

      ## Options

        - `:scheduled_at` - DateTime to schedule the job
        - `:priority` - Job priority (higher = more important)
        - `:unique` - Override unique settings
        - `:meta` - Additional job metadata
      """
      @spec enqueue(String.t(), map(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue(tenant_id, args, opts \\ []) when is_binary(tenant_id) do
        TenantQueues.insert_job(tenant_id, __MODULE__, args, Keyword.put(opts, :queue, @queue_type))
      end

      @doc """
      Enqueues a job to run at a specific time.
      """
      @spec enqueue_at(String.t(), map(), DateTime.t(), keyword()) ::
              {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue_at(tenant_id, args, %DateTime{} = scheduled_at, opts \\ []) do
        enqueue(tenant_id, args, Keyword.put(opts, :scheduled_at, scheduled_at))
      end

      @doc """
      Enqueues a job to run after a delay.
      """
      @spec enqueue_in(String.t(), map(), pos_integer(), keyword()) ::
              {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue_in(tenant_id, args, delay_seconds, opts \\ []) when is_integer(delay_seconds) do
        scheduled_at = DateTime.add(DateTime.utc_now(), delay_seconds, :second)
        enqueue(tenant_id, args, Keyword.put(opts, :scheduled_at, scheduled_at))
      end

      @doc """
      Returns the queue type for this worker.
      """
      @spec queue_type() :: atom()
      def queue_type, do: @queue_type

      # Oban.Worker implementation
      @impl Oban.Worker
      def perform(%Oban.Job{args: args, meta: meta} = job) do
        tenant_id = extract_tenant_id(args, meta)

        case tenant_id do
          nil ->
            Logger.error("#{__MODULE__}: Job missing tenant_id, args: #{inspect(args)}")
            {:error, :missing_tenant_id}

          tenant_id ->
            execute_with_tenant(args, tenant_id, job)
        end
      end

      defp extract_tenant_id(args, meta) do
        # Try meta first (added by TenantQueues), then args
        case meta do
          %{"tenant_id" => tenant_id} when is_binary(tenant_id) -> tenant_id
          %{tenant_id: tenant_id} when is_binary(tenant_id) -> tenant_id
          _ -> Map.get(args, "tenant_id") || Map.get(args, :tenant_id)
        end
      end

      defp execute_with_tenant(args, tenant_id, job) do
        try do
          case perform_for_tenant(args, tenant_id, job) do
            :ok ->
              if function_exported?(__MODULE__, :on_success, 3) do
                __MODULE__.on_success(args, tenant_id, :ok)
              end

              :ok

            {:ok, result} = success ->
              if function_exported?(__MODULE__, :on_success, 3) do
                __MODULE__.on_success(args, tenant_id, result)
              end

              success

            {:error, _reason} = error ->
              if function_exported?(__MODULE__, :on_failure, 4) do
                __MODULE__.on_failure(args, tenant_id, error, job)
              end

              error

            {:cancel, reason} ->
              Logger.info("#{__MODULE__}: Job cancelled for tenant #{tenant_id}: #{inspect(reason)}")
              {:cancel, reason}

            {:snooze, seconds} ->
              {:snooze, seconds}

            other ->
              Logger.warning("#{__MODULE__}: Unexpected return value: #{inspect(other)}")
              :ok
          end
        rescue
          e ->
            Logger.error(
              "#{__MODULE__}: Exception for tenant #{tenant_id}: #{Exception.message(e)}"
            )

            if function_exported?(__MODULE__, :on_failure, 4) do
              __MODULE__.on_failure(args, tenant_id, e, job)
            end

            reraise e, __STACKTRACE__
        end
      end

      # Allow workers to override these defaults
      defoverridable enqueue: 3, queue_type: 0
    end
  end
end
