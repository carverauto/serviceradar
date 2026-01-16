defmodule ServiceRadar.Oban.TenantQueues do
  @moduledoc """
  Oban queue management for background job processing.

  ## Queue Types

  - `:default` - General purpose jobs
  - `:service_checks` - Service check polling jobs
  - `:alerts` - Alert processing jobs
  - `:notifications` - Alert notification jobs
  - `:onboarding` - Edge onboarding jobs
  - `:events` - Event processing jobs
  - `:integrations` - Integration sync jobs

  ## Usage

      # Insert a job
      TenantQueues.insert_job(MyWorker, %{data: "value"}, queue: :service_checks)

      # Get queue name
      queue = TenantQueues.get_queue_name(:default)
      # => :default
  """

  use GenServer

  require Logger

  @ets_table :serviceradar_tenant_queues
  @queue_types [
    :default,
    :alerts,
    :service_checks,
    :notifications,
    :onboarding,
    :events,
    :sweeps,
    :edge,
    :integrations,
    :nats_accounts,
    :monitoring,
    :maintenance
  ]
  @default_concurrency %{
    default: 10,
    alerts: 5,
    service_checks: 10,
    notifications: 5,
    onboarding: 3,
    events: 10,
    sweeps: 20,
    edge: 10,
    integrations: 5,
    nats_accounts: 3,
    monitoring: 5,
    maintenance: 3
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
  Gets the Oban queue name for a queue type.
  """
  @spec get_queue_name(atom()) :: atom()
  def get_queue_name(queue_type) when is_atom(queue_type) do
    queue_type
  end

  @doc """
  Gets all queue names.
  """
  @spec get_all_queue_names() :: [atom()]
  def get_all_queue_names do
    @queue_types
  end

  @doc """
  Checks if Oban is running.
  """
  @spec ready?() :: boolean()
  def ready? do
    Process.whereis(Oban) != nil
  end

  @doc """
  Inserts a job.

  ## Options

    - `:queue` - Queue type (default: :default)
    - All other Oban.Job options (scheduled_at, priority, etc.)

  ## Examples

      TenantQueues.insert_job(MyWorker, %{data: "value"})
      TenantQueues.insert_job(MyWorker, %{data: "value"}, queue: :service_checks)
  """
  @spec insert_job(module(), map(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert_job(worker, args, opts \\ []) when is_atom(worker) do
    queue_type = Keyword.get(opts, :queue, :default)
    queue_name = get_queue_name(queue_type)

    job_opts =
      opts
      |> Keyword.drop([:queue])
      |> Keyword.put(:queue, queue_name)

    Oban.insert(worker.new(args, job_opts))
  end

  @doc """
  Inserts multiple jobs as a batch.
  """
  @spec insert_all_jobs([{module(), map(), keyword()}]) :: {:ok, [Oban.Job.t()]} | {:error, term()}
  def insert_all_jobs(jobs) when is_list(jobs) do
    changesets =
      Enum.map(jobs, fn {worker, args, opts} ->
        queue_type = Keyword.get(opts, :queue, :default)
        queue_name = get_queue_name(queue_type)

        job_opts =
          opts
          |> Keyword.drop([:queue])
          |> Keyword.put(:queue, queue_name)

        worker.new(args, job_opts)
      end)

    Oban.insert_all(changesets)
  end

  @doc """
  Gets queue statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    queue_stats =
      @queue_types
      |> Enum.map(fn queue_type ->
        counts = queue_counts(queue_type)
        {Atom.to_string(queue_type), counts}
      end)
      |> Map.new()

    %{
      ready: ready?(),
      queues: queue_stats,
      collected_at: DateTime.utc_now()
    }
  end

  defp queue_counts(queue) do
    Oban.check_queue(queue: queue)
    |> normalize_queue_counts()
  rescue
    _ -> %{paused: false, running: 0, available: 0}
  end

  defp normalize_queue_counts(%{paused: paused, running: running, available: available}) do
    %{paused: paused, running: running, available: available}
  end

  defp normalize_queue_counts(_), do: %{paused: false, running: 0, available: 0}

  @doc """
  Pauses all queues.
  """
  @spec pause_all() :: :ok
  def pause_all do
    Enum.each(@queue_types, &Oban.pause_queue(queue: &1))
    :ok
  end

  @doc """
  Resumes all queues.
  """
  @spec resume_all() :: :ok
  def resume_all do
    Enum.each(@queue_types, &Oban.resume_queue(queue: &1))
    :ok
  end

  @doc """
  Scales queue concurrency.
  """
  @spec scale_queue(atom(), pos_integer()) :: :ok
  def scale_queue(queue_type, limit) do
    Oban.scale_queue(queue: queue_type, limit: limit)
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
    # Create ETS table for tracking
    :ets.new(@ets_table, [:set, :public, :named_table, read_concurrency: true])

    Logger.info("TenantQueues started")

    {:ok, %{}}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    {:noreply, state}
  end
end
