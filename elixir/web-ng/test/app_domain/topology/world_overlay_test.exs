defmodule ServiceRadarWebNG.Topology.WorldOverlayTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldOverlay

  @moduletag :db_free

  test "durable publication hints leave a cold overlay alive until a world is installed" do
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tile_tasks = start_supervised!({Task.Supervisor, max_children: 4}, id: :tile_tasks)
    overlay_tasks = start_supervised!({Task.Supervisor, max_children: 4}, id: :overlay_tasks)

    cache = start_supervised!({WorldCache, name: __MODULE__.Cache, task_supervisor: tile_tasks, pubsub: pubsub})

    overlay =
      start_supervised!(
        {WorldOverlay, cache: cache, health: __MODULE__.Health, task_supervisor: overlay_tasks, pubsub: pubsub}
      )

    layout = "00000000-0000-4000-8000-000000000031"
    assert {:ok, key} = TileKey.new(layout, 0, 0, 0)
    revision = String.duplicate("a", 64)
    assert {:error, :not_ready} = WorldOverlay.fetch(key, revision, overlay)

    # This is the existing producer's public notification contract. There is
    # deliberately no invented encoded tile or injected native-world receipt.
    :ok =
      Phoenix.PubSub.broadcast(
        pubsub,
        "topology:world",
        {:topology_world_changed, %{layout_version: layout, generation: 1}}
      )

    assert {:error, :not_ready} = WorldOverlay.fetch(key, revision, overlay)
  end
end
