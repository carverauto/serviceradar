defmodule ServiceRadarWebNG.Topology.RuntimeSupervisor do
  @moduledoc """
  Restarts the topology producer when its published atlas store is lost.

  RuntimeGraph refreshes immediately on startup, so a store restart rebuilds the
  index instead of waiting for the next periodic refresh. A producer restart
  leaves the previously published index available to level readers.
  """

  use Supervisor

  alias ServiceRadarWebNG.Topology.AtlasStore
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([AtlasStore, RuntimeGraph], strategy: :rest_for_one)
  end
end
