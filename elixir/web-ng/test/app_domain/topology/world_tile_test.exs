defmodule ServiceRadarWebNG.Topology.WorldTileTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldTile

  @moduletag :db_free
  @version "00000000-0000-4000-8000-000000000478"

  test "installed geometry serves real encoded receipts and exact relation selectors across publications" do
    {:ok, _applications} = Application.ensure_all_started(:phoenix_pubsub)
    pubsub = __MODULE__.PubSub
    start_supervised!({Phoenix.PubSub, name: pubsub})
    tasks = start_supervised!({Task.Supervisor, max_children: 4})
    cache = start_supervised!({WorldCache, task_supervisor: tasks, pubsub: pubsub})
    world = world()
    {:ok, root} = TileKey.new(@version, 0, 0, 0)
    {:ok, child} = TileKey.new(@version, 3, 0, 0)
    manifest = %{layout_version: @version, generation: 1, zmax: 16}
    assert {:ok, prepared} = WorldTile.build(world, root)
    assert <<"ARROW1", _rest::binary>> = prepared.payload
    assert byte_size(prepared.payload) <= 262_144
    assert {:ok, _revision} = TileKey.content_revision(prepared.revision)
    assert :ok = WorldCache.install(world, manifest, prepared(world, manifest), cache)
    assert {:ok, first} = WorldCache.fetch(child, :foreground, cache)

    assert {:ok, %{relations: [relation], next_cursor: nil}} =
             TopologyAtlas.tile_relations(world, first.selection)

    assert relation.relation_id == "invented-link-a-b"
    assert [%{count: 1}] = first.flow_edges

    # A fresh native world has different resources but identical geometry. The
    # cache must reuse bytes/revision and attach a selector from the new world.
    next_world = world()
    assert :ok = WorldCache.install(next_world, %{manifest | generation: 2}, prepared(next_world, manifest), cache)
    assert {:ok, second} = WorldCache.fetch(child, :foreground, cache)
    assert second.payload == first.payload
    assert second.revision == first.revision
    assert second.generation == 2

    assert {:ok, %{relations: [%{relation_id: "invented-link-a-b"}]}} =
             TopologyAtlas.tile_relations(next_world, second.selection)

    {:ok, empty_key} = TileKey.new(@version, 3, 7, 7)
    assert {:ok, empty} = WorldCache.fetch(empty_key, :foreground, cache)
    assert <<"ARROW1", _rest::binary>> = empty.payload
    assert empty.flow_edges == []

    assert {:ok, %{relations: [], next_cursor: nil}} =
             TopologyAtlas.tile_relations(next_world, empty.selection)
  end

  test "wire and selection budget overflow generalize without losing membership" do
    for bytes <- [160_000, 1_048_576] do
      id = "invented:" <> String.duplicate("x", bytes)
      assert {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
      assert :ok = TopologyAtlas.add_positions(builder, [position(id, 100)])
      assert {:ok, world} = TopologyAtlas.finish_world(builder)
      assert {:ok, key} = TileKey.new(@version, 0, 0, 0)
      assert {:ok, tile} = WorldTile.build(world, key)
      assert byte_size(tile.payload) <= 262_144
      assert {:ok, health} = TopologyAtlas.new_health(world, 1)
      assert {:ok, %{glyphs: [glyph]}} = TopologyAtlas.tile_health(world, health, tile.selection)
      assert glyph.counts == %{total: 1, observed: 0, healthy: 0, unavailable: 0, unknown: 1}
      assert {:ok, selected} = TopologyAtlas.aggregate_selection(world, tile.selection, glyph.id)
      assert {:ok, %{member_count: 1}} = TopologyAtlas.aggregate_info(selected)
    end
  end

  defp prepared(world, manifest) do
    Map.new(TileKey.low_zoom(manifest), fn key ->
      {:ok, tile} = WorldTile.build(world, key)
      {key, tile}
    end)
  end

  defp world do
    {:ok, builder} = TopologyAtlas.new_builder(@version, 16)
    :ok = TopologyAtlas.add_positions(builder, [position("invented-device-a", 100), position("invented-device-b", 200)])

    :ok =
      TopologyAtlas.add_relations(builder, [
        %{relation_id: "invented-link-a-b", source_id: "invented-device-a", target_id: "invented-device-b"}
      ])

    {:ok, world} = TopologyAtlas.finish_world(builder)
    world
  end

  defp position(id, coordinate) do
    %{
      device_id: id,
      label: "Synthetic device",
      x: coordinate,
      y: coordinate,
      min_zoom: 0,
      parent_id: nil,
      component_id: "invented-component",
      component_z: 1,
      component_x: 0,
      component_y: 0,
      placement_depth: 4,
      active: true
    }
  end
end
