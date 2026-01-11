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

  require Logger

  alias ServiceRadar.EventWriter.Config

  @doc """
  Starts the EventWriter supervisor.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Config.load()

    Logger.info("Starting EventWriter supervisor",
      enabled: config.enabled,
      streams: length(config.streams)
    )

    children = [
      {ServiceRadar.EventWriter.Pipeline, config}
    ]

    Supervisor.init(children, strategy: :one_for_one)
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
              %{id: id, pid: child_pid, type: type, alive: is_pid(child_pid) and Process.alive?(child_pid)}
            end)
        }
    end
  end
end
