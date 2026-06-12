defmodule ServiceRadar.Observability.AnomalyDetection.Supervisor do
  @moduledoc """
  Supervisor for the real-time anomaly detection consumer.
  """

  use Supervisor

  alias ServiceRadar.Observability.AnomalyDetection.Config
  alias ServiceRadar.Observability.AnomalyDetection.Pipeline

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.load()

    Logger.info("Starting anomaly analysis supervisor",
      enabled: config.enabled,
      streams: length(config.streams),
      enabled_subjects: Enum.join(config.enabled_subjects, ",")
    )

    Supervisor.init([{Pipeline, config}], strategy: :one_for_one)
  end

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
