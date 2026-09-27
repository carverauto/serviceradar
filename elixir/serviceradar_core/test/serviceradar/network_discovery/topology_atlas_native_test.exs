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

  test "packaged detail cursors and selectors preserve persisted relation bindings" do
    positions =
      for index <- 1..67 do
        "sr:detail#{index}.example.com"
        |> position(index * 100, true)
        |> Map.put(:min_zoom, if(index <= 2, do: 0, else: 8))
      end

    [a, b, c | _] = positions

    bindings = [
      %{
        relation_id: "synthetic-link-b",
        source_id: a.device_id,
        target_id: b.device_id,
        source_if_index: 17,
        source_if_name: "port17",
        target_if_index: 29,
        target_if_name: "port29"
      },
      %{
        relation_id: "synthetic-link-a",
        source_id: b.device_id,
        target_id: c.device_id,
        source_if_index: 31,
        source_if_name: "port31",
        target_if_index: 47,
        target_if_name: "port47"
      }
    ]

    assert {:ok, builder} = TopologyAtlas.new_builder("synthetic-detail-layout", 16)
    assert :ok = TopologyAtlas.add_positions(builder, positions)
    assert :ok = TopologyAtlas.add_relations(builder, bindings)
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    assert {:ok, tile} = TopologyAtlas.tile(world, 0, 0, 0)
    assert is_reference(tile.selection)
    assert tile.selection_bytes > 0
    aggregate = Enum.find(tile.glyphs, &(&1.kind == :aggregate))
    assert {:ok, selection} = TopologyAtlas.aggregate_selection(world, tile.selection, aggregate.id)
    assert {:ok, %{nodes: [member], next_cursor: nil}} = TopologyAtlas.detail(world, {:aggregate_members, selection})
    assert member.device_id not in [a.device_id, b.device_id]
    assert member.device_id in Enum.map(positions, & &1.device_id)
    scope = {:component_members, "synthetic-component"}
    assert {:ok, first} = TopologyAtlas.detail(world, scope)
    assert length(first.nodes) == 64
    assert is_map(first.next_cursor)
    assert {:ok, %{nodes: remaining, next_cursor: nil}} = TopologyAtlas.detail(world, scope, first.next_cursor)
    assert length(remaining) == 3

    assert MapSet.new(Enum.map(first.nodes ++ remaining, & &1.device_id)) ==
             MapSet.new(Enum.map(positions, & &1.device_id))

    assert {:ok, %{nodes: neighbors, relations: [relation], incident_relations: 1}} =
             TopologyAtlas.detail(world, {:neighborhood, a.device_id})

    assert Enum.at(neighbors, relation.source).device_id == a.device_id
    assert Enum.at(neighbors, relation.target).device_id == b.device_id
    assert {:error, :invalid_cursor} = TopologyAtlas.detail(world, {:neighborhood, a.device_id}, %{})
    assert {:error, :invalid_request} = TopologyAtlas.detail(world, {:unsupported, a.device_id})

    assert {:ok, %{relations: selected, total_rendered_relations: 2, next_cursor: nil}} =
             TopologyAtlas.tile_relations(world, tile.selection)

    selected_by_id = Map.new(selected, &{&1.relation_id, &1})

    for binding <- bindings do
      row = Map.fetch!(selected_by_id, binding.relation_id)
      assert Map.take(row, Map.keys(binding)) == binding
      assert row.reversed == false
      assert Enum.at(tile.glyphs, row.source_glyph).id == binding.source_id
      assert Enum.any?(tile.edges, &(&1.id == row.rendered_edge_id))
    end

    assert {:ok, empty_builder} = TopologyAtlas.new_builder("synthetic-detail-layout", 16)
    assert {:ok, empty_world} = TopologyAtlas.finish_world(empty_builder)
    assert {:error, :stale_revision} = TopologyAtlas.tile_relations(empty_world, tile.selection)
    assert {:error, :stale_revision} = TopologyAtlas.detail(empty_world, {:aggregate_members, selection})
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
