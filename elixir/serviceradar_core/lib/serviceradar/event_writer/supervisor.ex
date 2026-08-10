defmodule ServiceRadar.EventWriter.Supervisor do
  @moduledoc """
  Supervisor for the EventWriter subsystem.

  Manages the Broadway pipeline and supporting processes for consuming
  NATS JetStream messages and writing them to CNPG hypertables.

  ## Supervision Strategy

  Uses `:one_for_one` strategy - if the Broadway pipeline crashes,
  it will be restarted independently without affecting other children.

  ## Children

  1. `EventWriter.Broadway` - The main Broadway pipeline for message processing
  """

  use Supervisor

  alias ServiceRadar.EventWriter.Config
  alias ServiceRadar.EventWriter.Pipeline

  require Logger

  @doc """
  Starts the EventWriter supervisor.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.load()
    flow_config = Config.load_flow()

    Logger.info("Starting EventWriter supervisor",
      enabled: config.enabled,
      streams: length(config.streams),
      flow_streams: length(flow_config.streams)
    )

    # Lag reporter watches both demand domains (shared + flow).
    lag_config = merge_lag_streams(config, flow_config)

    children =
      []
      |> maybe_pipeline(config, Pipeline)
      |> maybe_pipeline(flow_config, ServiceRadar.EventWriter.FlowPipeline)
      |> Kernel.++([
        {ServiceRadar.EventWriter.ConsumerLagReporter, lag_config},
        ServiceRadar.FlowAttribution.Correlator
      ])

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp merge_lag_streams(%Config{} = config, %Config{} = flow_config) do
    %{config | streams: config.streams ++ flow_config.streams}
  end

  defp maybe_pipeline(children, %Config{streams: streams} = config, name)
       when is_list(streams) and streams != [] do
    children ++ [{Pipeline, {config, [name: name]}}]
  end

  defp maybe_pipeline(children, %Config{} = config, name) do
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
