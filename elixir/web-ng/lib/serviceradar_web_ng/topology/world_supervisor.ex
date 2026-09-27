defmodule ServiceRadarWebNG.Topology.WorldSupervisor do
  @moduledoc """
  Owns the per-web-node native world, bounded tile tasks and publication loader.

  Losing the cache restarts the loader so its remembered generation cannot
  prevent a cold rebuild. Losing only the loader retains the last good world.
  """

  use Supervisor

  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldLoader

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    tile_tasks = ServiceRadarWebNG.Topology.TileTasks
    load_tasks = ServiceRadarWebNG.Topology.WorldLoadTasks
    watch_tasks = ServiceRadarWebNG.Topology.TileWatchTasks

    # Each owner and its task supervisors share a restart boundary. Otherwise
    # an owner crash loses its timeout while an orphan still occupies the pool.
    cache_children = [
      Supervisor.child_spec({Task.Supervisor, name: tile_tasks, max_children: 4}, id: tile_tasks),
      Supervisor.child_spec({Task.Supervisor, name: watch_tasks, max_children: 64}, id: watch_tasks),
      {WorldCache, task_supervisor: tile_tasks, pubsub: ServiceRadar.PubSub}
    ]

    loader_children = [
      Supervisor.child_spec({Task.Supervisor, name: load_tasks, max_children: 1}, id: load_tasks),
      {WorldLoader, name: WorldLoader, cache: WorldCache, task_supervisor: load_tasks, pubsub: ServiceRadar.PubSub}
    ]

    children = [group(:tile_cache, cache_children), group(:world_loader, loader_children)]
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp group(id, children) do
    %{
      id: id,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]},
      type: :supervisor
    }
  end
end
