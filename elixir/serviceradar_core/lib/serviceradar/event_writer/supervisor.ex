defmodule ServiceRadar.EventWriter.Supervisor do
  @moduledoc """
  The EventWriter workers one core replica runs.

  Every core replica runs this tree. Its pipelines bind the same JetStream
  durables as every other replica's, so JetStream gives each message to exactly
  one replica and ingestion scales with the replica count. The duties that need
  a single owner (creating and reconciling streams and durables, retiring old
  durables, stream ownership, lag reporting, flow correlation, and the streams
  whose processors rely on one writer) run under
  `ServiceRadar.EventWriter.CoordinatorSupervisor` instead.

  ## Supervision Strategy

  Uses `:one_for_one` strategy - if a Broadway pipeline crashes,
  it will be restarted independently without affecting other children.

  ## Children

  1. `EventWriter.ServiceCatalogCache` - node-local seen-cache for the OTel
     service catalog upsert; started before the pipelines that use it
  2. `EventWriter.AnomalyEpisodeGuardTables` - owner of the anomaly episode
     rate-guard and flood-tripwire counters; started before the pipelines
  3. `EventWriter.Pipeline` - the shared Broadway pipeline
  4. `EventWriter.FlowPipeline` - the raw-flow Broadway pipeline
  """

  use Supervisor

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline

  require Logger

  @doc """
  Whether this node runs EventWriter: `EVENT_WRITER_ENABLED` when set, else the
  `:event_writer_enabled` application setting.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("EVENT_WRITER_ENABLED") do
      nil ->
        Application.get_env(:serviceradar_core, :event_writer_enabled, false)

      value ->
        String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
    end
  end

  @doc """
  Starts the EventWriter supervisor.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.for_workers(Config.load())
    flow_config = Config.load_flow()

    Logger.info("Starting EventWriter worker supervisor",
      enabled: config.enabled,
      streams: length(config.streams),
      flow_streams: length(flow_config.streams),
      workers: config.workers
    )

    children =
      [
        ServiceRadar.EventWriter.ServiceCatalogCache,
        ServiceRadar.EventWriter.AnomalyEpisodeGuardTables
      ]
      |> maybe_pipeline(config, Pipeline)
      |> maybe_pipeline(flow_config, ServiceRadar.EventWriter.FlowPipeline)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def maybe_pipeline(children, %Config{streams: streams} = config, name)
      when is_list(streams) and streams != [] do
    children ++ [{Pipeline, {config, [name: name]}}]
  end

  def maybe_pipeline(children, %Config{} = config, name) do
    Logger.warning("Skipping EventWriter pipeline with no streams configured",
      pipeline: name,
      consumer_name: config.consumer_name
    )

    children
  end

  @doc """
  Returns the status of the EventWriter supervisor and its children.
  """
  @spec status() :: map()
  def status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{running: false}

      pid ->
        children = Supervisor.which_children(pid)

        %{
          running: true,
          pid: pid,
          children:
            Enum.map(children, fn {id, child_pid, type, _modules} ->
              %{
                id: id,
                pid: child_pid,
                type: type,
                alive: is_pid(child_pid) and Process.alive?(child_pid)
              }
            end)
        }
    end
  end
end
