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
        evidence_class: "direct-physical",
        role: "backbone",
        source_if_index: 17,
        source_if_name: "port17",
        target_if_index: 29,
        target_if_name: "port29"
      },
      %{
        relation_id: "synthetic-link-a",
        source_id: b.device_id,
        target_id: c.device_id,
        evidence_class: "hosted",
        role: "attachment",
        source_if_index: 29,
        source_if_name: "port29",
        target_if_index: 47,
        target_if_name: "port47"
      }
    ]

    loop_binding = %{
      relation_id: "synthetic-loop",
      source_id: c.device_id,
      target_id: c.device_id,
      source_if_index: 47,
      target_if_index: 47,
      evidence_class: "observed"
    }

    assert {:ok, builder} = TopologyAtlas.new_builder("synthetic-detail-layout", 16)
    assert :ok = TopologyAtlas.add_positions(builder, positions)
    assert :ok = TopologyAtlas.add_relations(builder, bindings ++ [loop_binding])
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    assert {:ok, tile} = TopologyAtlas.tile(world, 0, 0, 0)
    assert is_reference(tile.selection)
    assert tile.selection_bytes > 0
    aggregate = Enum.find(tile.glyphs, &(&1.kind == :aggregate))
    assert {:ok, selection} = TopologyAtlas.aggregate_selection(world, tile.selection, aggregate.id)
    assert {:ok, %{member_count: 1, retained_bytes: bytes}} = TopologyAtlas.aggregate_info(selection)
    assert bytes > 0
    assert {:ok, %{nodes: [member], next_cursor: nil}} = TopologyAtlas.detail(world, {:aggregate_members, selection})
    refute member.device_id in [a.device_id, b.device_id]
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
    assert relation.evidence_class == "direct-physical"
    assert relation.role == "backbone"
    assert {:error, :invalid_cursor} = TopologyAtlas.detail(world, {:neighborhood, a.device_id}, %{})
    assert {:error, :invalid_request} = TopologyAtlas.detail(world, {:unsupported, a.device_id})

    assert {:ok, %{relations: [first_binding], total_rendered_relations: 2, next_cursor: next}} =
             TopologyAtlas.tile_relations(world, tile.selection, nil, 1)

    assert is_map(next)

    assert {:ok, %{relations: [second_binding], total_rendered_relations: 2, next_cursor: tail}} =
             TopologyAtlas.tile_relations(world, tile.selection, next, 1)

    if tail do
      assert {:ok, %{relations: [], next_cursor: nil}} = TopologyAtlas.tile_relations(world, tile.selection, tail, 1)
    end

    # Degrees include the other page and the non-rendered self-relation. The
    # latter contributes once even though both ends name the same interface.
    selected = [first_binding, second_binding]

    selected_by_id = Map.new(selected, &{&1.relation_id, &1})
    assert selected_by_id["synthetic-link-b"].source_interface_degree == 1
    assert selected_by_id["synthetic-link-b"].target_interface_degree == 2
    assert selected_by_id["synthetic-link-a"].source_interface_degree == 2
    assert selected_by_id["synthetic-link-a"].target_interface_degree == 2

    for binding <- bindings do
      assert {:ok, %{relation: picked, nodes: [source, target]}} = TopologyAtlas.relation(world, binding.relation_id)
      assert Map.take(picked, Map.keys(binding)) == binding
      assert source == Enum.find(positions, &(&1.device_id == binding.source_id))
      assert target == Enum.find(positions, &(&1.device_id == binding.target_id))

      row = Map.fetch!(selected_by_id, binding.relation_id)
      assert Map.take(row, Map.keys(binding)) == binding
      assert row.reversed == false
      assert Enum.at(tile.glyphs, row.source_glyph).id == binding.source_id
      assert Enum.any?(tile.edges, &(&1.id == row.rendered_edge_id))
    end

    assert {:error, :not_found} = TopologyAtlas.relation(world, "synthetic-missing-link")
    assert {:ok, %{nodes: [^c, ^c]}} = TopologyAtlas.relation(world, loop_binding.relation_id)
    assert {:error, :invalid_identity} = TopologyAtlas.relation(world, nil)
    assert {:error, :invalid_identity} = TopologyAtlas.relation(world, "")

    assert {:ok, empty_builder} = TopologyAtlas.new_builder("synthetic-detail-layout", 16)
    assert {:ok, empty_world} = TopologyAtlas.finish_world(empty_builder)
    assert {:error, :stale_revision} = TopologyAtlas.tile_relations(empty_world, tile.selection)
    assert {:error, :stale_revision} = TopologyAtlas.detail(empty_world, {:aggregate_members, selection})
  end

  test "packaged health updates are atomic, revision-bound, and separate from tile geometry" do
    a = position("sr:health-a.example.com", 100, true)
    b = position("sr:health-b.example.com", 200, true)
    c = position("sr:health-c.example.com", 300, true)
    world = cold_world([a, b])
    epoch = 0xFEDCBA9876543210
    assert {:ok, health} = TopologyAtlas.new_health(world, epoch)

    assert {:ok, %{epoch: "fedcba9876543210", observed: 0, total: 2, retained_bytes: bytes}} =
             TopologyAtlas.health_info(world, health)

    assert bytes > 0
    assert {:ok, %{ids: [id], next_cursor: cursor}} = TopologyAtlas.device_ids_page(world, nil, 1)
    assert {:ok, %{ids: [other], next_cursor: nil}} = TopologyAtlas.device_ids_page(world, cursor, 1)
    assert MapSet.new([id, other]) == MapSet.new([a.device_id, b.device_id])
    assert {:ok, tile} = TopologyAtlas.tile(world, 0, 0, 0)

    assert {:ok, %{applied: 2, revision: 1}} =
             TopologyAtlas.apply_health(world, health, 9, [
               %{device_id: a.device_id, state: :unavailable},
               %{device_id: b.device_id, state: :healthy}
             ])

    assert {:error, :invalid_request} =
             TopologyAtlas.apply_health(world, health, 10, [
               %{device_id: a.device_id, state: :healthy},
               %{device_id: b.device_id, state: :invalid}
             ])

    assert {:ok, status} = TopologyAtlas.tile_health(world, health, tile.selection)
    assert status.epoch == "fedcba9876543210"
    assert status.revision == 1
    assert status.observation_sequence == 9
    assert status.tile_revision == tile.revision
    by_id = Map.new(status.glyphs, &{&1.id, &1.counts})
    assert by_id[a.device_id] == %{healthy: 0, unavailable: 1, unknown: 0, observed: 1, total: 1}
    assert by_id[b.device_id] == %{healthy: 1, unavailable: 0, unknown: 0, observed: 1, total: 1}
    assert {:ok, %{revision: same_revision}} = TopologyAtlas.tile(world, 0, 0, 0)
    assert same_revision == tile.revision

    replacement = cold_world([a, c])
    assert {:error, :stale_revision} = TopologyAtlas.health_info(replacement, health)
    assert {:error, :stale_revision} = TopologyAtlas.device_ids_page(replacement, cursor, 1)
    assert {:ok, rebased} = TopologyAtlas.rebase_health(world, health, replacement, epoch)
    assert {:ok, %{epoch: "fedcba9876543210", observed: 1, total: 2}} = TopologyAtlas.health_info(replacement, rebased)
    assert {:ok, replacement_tile} = TopologyAtlas.tile(replacement, 0, 0, 0)
    assert {:ok, replacement_health} = TopologyAtlas.tile_health(replacement, rebased, replacement_tile.selection)
    replacement_by_id = Map.new(replacement_health.glyphs, &{&1.id, &1.counts})
    assert replacement_by_id[a.device_id].unavailable == 1
    assert replacement_by_id[c.device_id] == %{healthy: 0, unavailable: 0, unknown: 1, observed: 0, total: 1}
  end

  test "packaged aggregate profile recovers a descriptor budget failure without truncating identity" do
    id = "sr:" <> String.duplicate("x", 1_048_576)
    world = cold_world([position(id, 100, true)])
    assert {:error, :selection_budget_exceeded} = TopologyAtlas.tile(world, 0, 0, 0)

    assert {:ok, %{profile: :aggregate_only, glyphs: [%{kind: :aggregate, count: 1}]} = tile} =
             TopologyAtlas.tile(world, 0, 0, 0, %{nodes: 128, edges: 256, profile: :aggregate_only})

    assert tile.selection_bytes < 4096
    assert {:ok, %{device_id: ^id}} = TopologyAtlas.search(world, id)
  end

  defp cold_world(positions) do
    assert {:ok, builder} = TopologyAtlas.new_builder("synthetic-health-layout", 16)
    assert :ok = TopologyAtlas.add_positions(builder, positions)
    assert {:ok, world} = TopologyAtlas.finish_world(builder)
    world
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
