defmodule ServiceRadarWebNGWeb.DashboardTopologyPluginTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Topology

  @moduletag :db_free

  test "supports? detects graph payloads" do
    assert Topology.supports?(%{"results" => [%{"nodes" => [], "edges" => []}]})
    refute Topology.supports?(%{"results" => [%{"a" => 1}]})
  end

  test "build merges nodes and edges across rows and normalizes ids" do
    response = %{
      "results" => [
        %{
          "nodes" => [%{"device_id" => "dev-1", "hostname" => "device-1"}],
          "edges" => [%{"source" => "dev-1", "target" => "dev-2", "type" => "links_to"}]
        },
        %{
          "nodes" => [%{"id" => "dev-2", "label" => "device-2"}],
          "edges" => []
        }
      ]
    }

    assert {:ok, assigns} = Topology.build(response)
    assert length(assigns.nodes) == 2
    assert Enum.any?(assigns.nodes, &(&1.id == "dev-1"))
    assert Enum.any?(assigns.nodes, &(&1.id == "dev-2"))
    assert [%{source: "dev-1", target: "dev-2"}] = assigns.edges
  end

  test "build caps nodes and reports the hidden count" do
    nodes =
      for idx <- 1..125 do
        %{"id" => "node-#{idx}", "label" => "Node #{idx}"}
      end

    edges =
      for idx <- 1..124 do
        %{"source" => "node-#{idx}", "target" => "node-#{idx + 1}"}
      end

    assert {:ok, assigns} = Topology.build(%{"results" => [%{"nodes" => nodes, "edges" => edges}]})
    assert length(assigns.nodes) == 120
    assert assigns.total_node_count == 125
    assert assigns.truncated_node_count == 5

    node_ids = MapSet.new(assigns.nodes, & &1.id)

    assert Enum.all?(assigns.edges, fn edge ->
             MapSet.member?(node_ids, edge.source) and MapSet.member?(node_ids, edge.target)
           end)

    html =
      render_component(&Topology.render/1,
        id: "topology-test",
        nodes: assigns.nodes,
        edges: assigns.edges,
        total_node_count: assigns.total_node_count,
        truncated_node_count: assigns.truncated_node_count,
        selected_node_id: nil,
        myself: "topology-test"
      )

    assert html =~ "Nodes:"
    assert html =~ "of <span class=\"font-mono\">125</span>"
    assert html =~ "+5 more"
  end

  test "fallback ids are stable canonical digests" do
    left = %{"label" => "", "z" => 1, "a" => %{"b" => 2}}
    right = %{"a" => %{"b" => 2}, "z" => 1, "label" => ""}

    assert {:ok, left_assigns} = Topology.build(%{"results" => [%{"nodes" => [left], "edges" => []}]})
    assert {:ok, right_assigns} = Topology.build(%{"results" => [%{"nodes" => [right], "edges" => []}]})

    [left_node] = left_assigns.nodes
    [right_node] = right_assigns.nodes

    assert left_node.id == right_node.id
    assert String.starts_with?(left_node.id, "node:")
    refute left_node.id == Integer.to_string(:erlang.phash2(left))
  end

  test "build uses stable fallback ids for nodes without explicit ids" do
    response = %{
      "results" => [
        %{
          "nodes" => [
            %{"label" => "implicit", "attrs" => %{"b" => 2, "a" => 1}},
            %{"attrs" => %{"a" => 1, "b" => 2}, "label" => "implicit"}
          ],
          "edges" => []
        }
      ]
    }

    assert {:ok, assigns} = Topology.build(response)
    assert [%{id: id, label: "implicit"}] = assigns.nodes
    assert String.starts_with?(id, "node:")
    assert byte_size(id) == byte_size("node:") + 16
  end

  test "build caps oversized topology with a visible truncation node" do
    nodes =
      Enum.map(1..122, fn idx ->
        %{"id" => "node-#{idx}", "label" => "Node #{idx}"}
      end)

    response = %{"results" => [%{"nodes" => nodes, "edges" => []}]}

    assert {:ok, assigns} = Topology.build(response)
    assert length(assigns.nodes) == 120
    assert %{id: "__truncated_nodes__", label: "+3 more", raw: %{"truncated" => true}} = List.last(assigns.nodes)
  end
end
