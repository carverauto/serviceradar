defmodule ServiceRadar.Oban.TenantWorker do
  @moduledoc """
  Behaviour for ServiceRadar Oban workers.

  Extends Oban.Worker with convenience functions for job enqueueing
  and consistent error handling patterns.

  ## Usage

      defmodule MyApp.Workers.SyncWorker do
        use ServiceRadar.Oban.TenantWorker,
          queue_type: :integrations,
          max_attempts: 5

        @impl true
        def perform_job(args, job) do
          # Your job logic here
          :ok
        end
      end

  ## Enqueueing Jobs

      # Use the worker's enqueue function
      SyncWorker.enqueue(%{source_id: "123"})

      # Or use TenantQueues directly
      TenantQueues.insert_job(SyncWorker, %{source_id: "123"})

  ## Options

    - `:queue_type` - Queue type atom (default: :default)
    - `:max_attempts` - Maximum retry attempts (default: 3)
    - `:priority` - Default job priority (default: 0)
    - `:unique` - Oban unique job options (optional)

  ## Callbacks

    - `perform_job/2` - Required. Called with (args, job)
    - `on_success/2` - Optional. Called after successful execution
    - `on_failure/3` - Optional. Called after failed execution
  """

  @doc """
  Callback for job execution.

  Receives the job args and full Oban.Job struct.
  Must return `:ok`, `{:ok, result}`, or `{:error, reason}`.
  """
  @callback perform_job(args :: map(), job :: Oban.Job.t()) ::
              :ok | {:ok, term()} | {:error, term()} | {:cancel, term()} | {:snooze, pos_integer()}

  @doc """
  Optional callback after successful job execution.
  """
  @callback on_success(args :: map(), result :: term()) :: :ok

  @doc """
  Optional callback after failed job execution.
  """
  @callback on_failure(args :: map(), error :: term(), job :: Oban.Job.t()) :: :ok

  @optional_callbacks [on_success: 2, on_failure: 3]

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
      Enqueues a job.

      ## Options

        - `:scheduled_at` - DateTime to schedule the job
        - `:priority` - Job priority (higher = more important)
        - `:unique` - Override unique settings
        - `:meta` - Additional job metadata
      """
      @spec enqueue(map(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue(args, opts \\ []) do
        TenantQueues.insert_job(__MODULE__, args, Keyword.put(opts, :queue, @queue_type))
      end

      @doc """
      Enqueues a job to run at a specific time.
      """
      @spec enqueue_at(map(), DateTime.t(), keyword()) ::
              {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue_at(args, %DateTime{} = scheduled_at, opts \\ []) do
        enqueue(args, Keyword.put(opts, :scheduled_at, scheduled_at))
      end

      @doc """
      Enqueues a job to run after a delay.
      """
      @spec enqueue_in(map(), pos_integer(), keyword()) ::
              {:ok, Oban.Job.t()} | {:error, term()}
      def enqueue_in(args, delay_seconds, opts \\ []) when is_integer(delay_seconds) do
        scheduled_at = DateTime.add(DateTime.utc_now(), delay_seconds, :second)
        enqueue(args, Keyword.put(opts, :scheduled_at, scheduled_at))
      end

      @doc """
      Returns the queue type for this worker.
      """
      @spec queue_type() :: atom()
      def queue_type, do: @queue_type

      # Oban.Worker implementation
      @impl Oban.Worker
      def perform(%Oban.Job{args: args} = job) do
        execute_job(args, job)
      end

      defp execute_job(args, job) do
        perform_job(args, job)
        |> handle_perform_result(args, job)
      rescue
        e ->
          Logger.error("#{__MODULE__}: Exception: #{Exception.message(e)}")

          if function_exported?(__MODULE__, :on_failure, 3) do
            __MODULE__.on_failure(args, e, job)
          end

          reraise e, __STACKTRACE__
      end

      defp handle_perform_result(result, args, job) do
        case result do
          :ok ->
            maybe_on_success(args, :ok)
            :ok

          {:ok, payload} ->
            maybe_on_success(args, payload)
            {:ok, payload}

          {:error, _reason} = error ->
            maybe_on_failure(args, error, job)
            error

          {:cancel, reason} ->
            Logger.info("#{__MODULE__}: Job cancelled: #{inspect(reason)}")
            {:cancel, reason}

          {:snooze, seconds} ->
            {:snooze, seconds}

          other ->
            Logger.warning("#{__MODULE__}: Unexpected return value: #{inspect(other)}")
            :ok
        end
      end

      defp maybe_on_success(args, result) do
        if function_exported?(__MODULE__, :on_success, 2) do
          __MODULE__.on_success(args, result)
        end
      end

      defp maybe_on_failure(args, error, job) do
        if function_exported?(__MODULE__, :on_failure, 3) do
          __MODULE__.on_failure(args, error, job)
        end
      end

      # Allow workers to override these defaults
      @impl ServiceRadar.Oban.TenantWorker
      def on_success(_args, _result), do: :ok

      @impl ServiceRadar.Oban.TenantWorker
      def on_failure(_args, _error, _job), do: :ok

      defoverridable enqueue: 2, queue_type: 0, on_success: 2, on_failure: 3
    end
  end
end
