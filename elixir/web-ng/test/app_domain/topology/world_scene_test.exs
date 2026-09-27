defmodule ServiceRadarWebNG.Topology.WorldSceneTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.WorldScene

  @moduletag :db_free

  test "detail pages carry their identity and cursor in bounded deterministic Arrow" do
    level = level()
    assert {:ok, encoded} = WorldScene.encode(level)
    assert <<"ARROW1", _rest::binary>> = encoded.payload
    assert byte_size(encoded.payload) <= 262_144
    assert :binary.match(encoded.payload, level.level_id) != :nomatch
    assert :binary.match(encoded.payload, level.next_cursor) != :nomatch
    assert {:ok, ^encoded} = WorldScene.encode(level)

    next = %{level | next_cursor: "invented-next-page-b"}
    assert {:ok, changed} = WorldScene.encode(next)
    refute encoded.revision == changed.revision
  end

  test "optional inventory is deferred before wire overflow, without dropping page members" do
    level = level()
    [first, second] = level.nodes
    first = %{first | details: Map.put(first.details, :inventory_notes, String.duplicate("x", 270_000))}
    assert {:ok, encoded} = WorldScene.encode(%{level | nodes: [first, second]})
    assert byte_size(encoded.payload) <= 262_144
    assert :binary.match(encoded.payload, "inventory,camera") != :nomatch
    assert :binary.match(encoded.payload, first.id) != :nomatch
    assert :binary.match(encoded.payload, second.id) != :nomatch

    huge = %{first | id: String.duplicate("invented", 40_000)}
    assert {:error, :payload_too_large} = WorldScene.encode(%{level | nodes: [huge], edges: []})
  end

  test "rejects an unbounded page, duplicate identities and dangling relations" do
    level = level()
    assert {:error, :payload_too_large} = WorldScene.encode(%{level | nodes: List.duplicate(hd(level.nodes), 129)})
    assert {:error, :invalid_detail} = WorldScene.encode(%{level | nodes: List.duplicate(hd(level.nodes), 2)})
    assert {:error, :invalid_detail} = WorldScene.encode(%{level | nodes: [hd(level.nodes)]})
  end

  defp level do
    %{
      level_id: "world-detail:invented-page-a",
      parent_level_id: nil,
      layout_version: "00000000-0000-4000-8000-000000000478",
      generation: 1,
      revision: 123,
      structure_revision: 456,
      next_cursor: "invented-next-page-a",
      kind: "neighborhood",
      nodes:
        for id <- ["invented-router-a", "invented-router-b"] do
          %{id: id, label: "Synthetic router", health_signal: :unknown, details: %{id: id, type: "router"}}
        end,
      edges: [
        %{
          id: "invented-relation-a-b",
          source: "invented-router-a",
          target: "invented-router-b",
          evidence_class: "direct",
          role: "physical"
        }
      ]
    }
  end
end
