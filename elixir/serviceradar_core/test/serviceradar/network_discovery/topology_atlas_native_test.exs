defmodule ServiceRadar.TopologyAtlasNativeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.TopologyAtlas

  @moduletag :db_free

  test "packaged native world consumes a bounded builder and excludes inactive reservations" do
    a = position("sr:host0001.example.com", 100, true)
    b = position("sr:host0002.example.com", 200, false)

    assert {:ok, builder} = TopologyAtlas.new_builder("synthetic-native-layout", 16)
    oversized = for index <- 1..501, do: position("sr:host#{index}.example.com", index, true)
    assert {:error, _} = TopologyAtlas.add_positions(builder, oversized)
    assert :ok = TopologyAtlas.add_positions(builder, [a, b])
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    assert {:error, _} = TopologyAtlas.finish_world(builder)
    assert {:ok, %{node_count: 1, relation_count: 0, extent: 16_777_216}} = TopologyAtlas.world_info(world)
    assert {:ok, %{device_id: "sr:host0001.example.com", x: 100, y: 100}} = TopologyAtlas.search(world, a.device_id)
    assert {:error, :not_found} = TopologyAtlas.search(world, b.device_id)

    assert {:ok, %{device_count: 1, glyphs: [%{id: "sr:host0001.example.com", count: 1, kind: :device}], edges: []}} =
             TopologyAtlas.tile(world, 0, 0, 0)

    assert {:error, :invalid_tile} = TopologyAtlas.tile(world, 0, 0, 0, %{nodes: 129, edges: 256})
  end

  defp position(id, coordinate, active) do
    %{
      device_id: id,
      label: "Synthetic device",
      x: coordinate,
      y: coordinate,
      min_zoom: 0,
      parent_id: nil,
      component_id: "synthetic-component",
      component_z: 1,
      component_x: 0,
      component_y: 0,
      placement_depth: 4,
      active: active
    }
  end
end
