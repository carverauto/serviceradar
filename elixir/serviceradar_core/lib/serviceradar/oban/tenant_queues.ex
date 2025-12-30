defmodule ServiceRadar.Oban.TenantQueues do
  @moduledoc """
  Per-tenant Oban queue management for multi-tenant job isolation.

  Provides complete tenant isolation for background jobs by:
  - Creating dedicated queues per tenant
  - Routing jobs to tenant-specific queues
  - Tracking queue state per tenant
  - Supporting dynamic queue provisioning

  ## Queue Naming Convention

  Queues are named `t_{tenant_hash}_{job_type}` where:
  - `tenant_hash` is the first 8 chars of SHA256(tenant_id)
  - `job_type` is the queue category (default, polling, alerts, sync, etc.)

  Examples:
  - `t_a1b2c3d4_default`
  - `t_a1b2c3d4_polling`
  - `t_a1b2c3d4_alerts`

  ## Usage

      # Provision queues for a new tenant
      TenantQueues.provision_tenant(tenant_id)

      # Insert a job for a tenant
      TenantQueues.insert_job(tenant_id, MyWorker, %{data: "value"}, queue: :polling)

      # Get queue name for a tenant
      queue = TenantQueues.get_queue_name(tenant_id, :default)
      # => :t_a1b2c3d4_default

  ## Queue Types

  Each tenant gets these queues by default:
  - `:default` - General purpose jobs
  - `:polling` - Service check polling jobs
  - `:alerts` - Alert processing and notifications
  - `:sync` - Data synchronization jobs
  - `:events` - Event processing jobs

  ## Architecture

  Queue state is tracked in an ETS table for fast lookups.
  Queue provisioning is idempotent - safe to call multiple times.
  """

  use GenServer

  require Logger

  @ets_table :serviceradar_tenant_queues
  @queue_types [:default, :polling, :alerts, :sync, :events]
  @default_concurrency %{
    default: 10,
    polling: 20,
    alerts: 5,
    sync: 10,
    events: 15
  }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Starts the TenantQueues server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the child spec for supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Provisions queues for a tenant.

  Creates all standard queues for the tenant and starts them in Oban.
  Safe to call multiple times (idempotent).

  ## Options

    - `:queue_types` - List of queue types to create (default: all)
    - `:concurrency` - Map of queue_type => concurrency (default: standard values)

  ## Examples

      TenantQueues.provision_tenant("tenant-uuid")
      TenantQueues.provision_tenant("tenant-uuid", queue_types: [:default, :polling])
  """
  @spec provision_tenant(String.t(), keyword()) :: :ok | {:error, term()}
  def provision_tenant(tenant_id, opts \\ []) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:provision_tenant, tenant_id, opts})
  end

  @doc """
  Deprovisions queues for a tenant.

  Pauses and removes tenant's queues from Oban.
  Existing jobs will complete but no new jobs will be processed.
  """
  @spec deprovision_tenant(String.t()) :: :ok
  def deprovision_tenant(tenant_id) when is_binary(tenant_id) do
    GenServer.call(__MODULE__, {:deprovision_tenant, tenant_id})
  end

  @doc """
  Gets the Oban queue name for a tenant and queue type.

  Returns an atom like `:t_a1b2c3d4_default`.
  """
  @spec get_queue_name(String.t(), atom()) :: atom()
  def get_queue_name(tenant_id, queue_type) when is_binary(tenant_id) and is_atom(queue_type) do
    hash = tenant_hash(tenant_id)
    String.to_atom("t_#{hash}_#{queue_type}")
  end

  @doc """
  Gets all queue names for a tenant.
  """
  @spec get_all_queue_names(String.t()) :: [atom()]
  def get_all_queue_names(tenant_id) when is_binary(tenant_id) do
    Enum.map(@queue_types, &get_queue_name(tenant_id, &1))
  end

  @doc """
  Checks if a tenant has been provisioned.
  """
  @spec tenant_provisioned?(String.t()) :: boolean()
  def tenant_provisioned?(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@ets_table, {:tenant, tenant_id}) do
      [{_, :provisioned}] -> true
      _ -> false
    end
  end

  @doc """
  Inserts a job for a specific tenant.

  Routes the job to the tenant's queue based on the queue type.
  Adds tenant_id to job meta for tracking.

  ## Options

    - `:queue` - Queue type (default: :default)
    - All other Oban.Job options (scheduled_at, priority, etc.)

  ## Examples

      TenantQueues.insert_job(tenant_id, MyWorker, %{data: "value"})
      TenantQueues.insert_job(tenant_id, MyWorker, %{}, queue: :polling, priority: 1)
  """
  @spec insert_job(String.t(), module(), map(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def insert_job(tenant_id, worker, args, opts \\ []) when is_binary(tenant_id) do
    queue_type = Keyword.get(opts, :queue, :default)
    queue_name = get_queue_name(tenant_id, queue_type)

    # Add tenant_id to job meta
    meta = Map.merge(Keyword.get(opts, :meta, %{}), %{tenant_id: tenant_id})

    job_opts =
      opts
      |> Keyword.drop([:queue, :meta])
      |> Keyword.put(:queue, queue_name)
      |> Keyword.put(:meta, meta)

    args
    |> worker.new(job_opts)
    |> Oban.insert()
  end

  @doc """
  Inserts multiple jobs for a tenant as a batch.
  """
  @spec insert_all_jobs(String.t(), [{module(), map(), keyword()}]) ::
          {:ok, [Oban.Job.t()]} | {:error, term()}
  def insert_all_jobs(tenant_id, jobs) when is_binary(tenant_id) and is_list(jobs) do
    changesets =
      Enum.map(jobs, fn {worker, args, opts} ->
        queue_type = Keyword.get(opts, :queue, :default)
        queue_name = get_queue_name(tenant_id, queue_type)
        meta = Map.merge(Keyword.get(opts, :meta, %{}), %{tenant_id: tenant_id})

        job_opts =
          opts
          |> Keyword.drop([:queue, :meta])
          |> Keyword.put(:queue, queue_name)
          |> Keyword.put(:meta, meta)

        worker.new(args, job_opts)
      end)

    Oban.insert_all(changesets)
  end

  @doc """
  Lists all provisioned tenants.
  """
  @spec list_provisioned_tenants() :: [String.t()]
  def list_provisioned_tenants do
    :ets.match(@ets_table, {{:tenant, :"$1"}, :provisioned})
    |> Enum.map(fn [tenant_id] -> tenant_id end)
  end

  @doc """
  Gets queue statistics for a tenant.
  """
  @spec get_tenant_stats(String.t()) :: map()
  def get_tenant_stats(tenant_id) when is_binary(tenant_id) do
    queue_names = get_all_queue_names(tenant_id)

    stats =
      queue_names
      |> Enum.map(fn queue ->
        queue_str = Atom.to_string(queue)

        counts =
          Oban.check_queue(queue: queue)
          |> case do
            %{paused: paused, running: running, available: available} ->
              %{paused: paused, running: running, available: available}

            _ ->
              %{paused: false, running: 0, available: 0}
          end

        {queue_str, counts}
      end)
      |> Map.new()

    %{
      tenant_id: tenant_id,
      provisioned: tenant_provisioned?(tenant_id),
      queues: stats,
      collected_at: DateTime.utc_now()
    }
  end

  @doc """
  Pauses all queues for a tenant.
  """
  @spec pause_tenant(String.t()) :: :ok
  def pause_tenant(tenant_id) when is_binary(tenant_id) do
    get_all_queue_names(tenant_id)
    |> Enum.each(&Oban.pause_queue(queue: &1))

    :ok
  end

  @doc """
  Resumes all queues for a tenant.
  """
  @spec resume_tenant(String.t()) :: :ok
  def resume_tenant(tenant_id) when is_binary(tenant_id) do
    get_all_queue_names(tenant_id)
    |> Enum.each(&Oban.resume_queue(queue: &1))

    :ok
  end

  @doc """
  Scales queue concurrency for a tenant.
  """
  @spec scale_tenant_queue(String.t(), atom(), pos_integer()) :: :ok
  def scale_tenant_queue(tenant_id, queue_type, limit) do
    queue_name = get_queue_name(tenant_id, queue_type)
    Oban.scale_queue(queue: queue_name, limit: limit)
    :ok
  end

  @doc """
  Returns the list of standard queue types.
  """
  @spec queue_types() :: [atom()]
  def queue_types, do: @queue_types

  @doc """
  Returns default concurrency settings.
  """
  @spec default_concurrency() :: map()
  def default_concurrency, do: @default_concurrency

  # ===========================================================================
  # Server Callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for tracking provisioned tenants
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

    # Provision queues for existing tenants
    provision_existing_tenants()

    {:ok, %{}}
  end

  @impl true
  def handle_call({:provision_tenant, tenant_id, opts}, _from, state) do
    result = do_provision_tenant(tenant_id, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:deprovision_tenant, tenant_id}, _from, state) do
    result = do_deprovision_tenant(tenant_id)
    {:reply, result, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Ignore stray Task messages from async decrypt/transform work in Ash reads.
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state}
  end

  # ===========================================================================
  # Private Functions
  # ===========================================================================

  defp tenant_hash(tenant_id) do
    :crypto.hash(:sha256, tenant_id)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  defp provision_existing_tenants do
    # Query all tenants from the database and provision their queues
    case Ash.read(ServiceRadar.Identity.Tenant, authorize?: false) do
      {:ok, tenants} ->
        Enum.each(tenants, fn tenant ->
          do_provision_tenant(tenant.id, [])
        end)

        Logger.info("Provisioned Oban queues for #{length(tenants)} existing tenants")

      {:error, reason} ->
        Logger.warning("Failed to load tenants for queue provisioning: #{inspect(reason)}")
    end
  rescue
    # Database might not be available during startup
    e ->
      Logger.debug("Skipping tenant queue provisioning: #{inspect(e)}")
  end

  defp do_provision_tenant(tenant_id, opts) do
    queue_types = Keyword.get(opts, :queue_types, @queue_types)
    concurrency = Keyword.get(opts, :concurrency, @default_concurrency)

    # Create queue configurations
    queues =
      Enum.map(queue_types, fn type ->
        queue_name = get_queue_name(tenant_id, type)
        limit = Map.get(concurrency, type, 10)
        {queue_name, limit}
      end)

    # Start each queue in Oban
    Enum.each(queues, fn {queue_name, limit} ->
      # Use Oban's scale_queue to start/configure the queue
      # This is idempotent - works for both new and existing queues
      try do
        Oban.scale_queue(queue: queue_name, limit: limit)
      rescue
        # Queue might not exist yet, which is fine for Oban 2.18+
        _ -> :ok
      end
    end)

    # Mark tenant as provisioned
    :ets.insert(@ets_table, {{:tenant, tenant_id}, :provisioned})

    # Store queue names for this tenant
    Enum.each(queue_types, fn type ->
      queue_name = get_queue_name(tenant_id, type)
      :ets.insert(@ets_table, {{:queue, tenant_id, type}, queue_name})
    end)

    Logger.info("Provisioned Oban queues for tenant: #{tenant_id}")
    :ok
  end

  defp do_deprovision_tenant(tenant_id) do
    queue_names = get_all_queue_names(tenant_id)

    # Pause all tenant queues (jobs will drain but no new ones processed)
    Enum.each(queue_names, fn queue ->
      try do
        Oban.pause_queue(queue: queue)
      rescue
        _ -> :ok
      end
    end)

    # Remove from ETS
    :ets.delete(@ets_table, {:tenant, tenant_id})

    Enum.each(@queue_types, fn type ->
      :ets.delete(@ets_table, {:queue, tenant_id, type})
    end)

    Logger.info("Deprovisioned Oban queues for tenant: #{tenant_id}")
    :ok
  end
end
