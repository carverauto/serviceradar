defmodule ServiceRadarWebNG.Topology.AtlasSourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasSource

  @moduletag :db_free

  test "Dgraph retains isolated canonical vertices and unions missing relation endpoints" do
    edges = [%{source: "sr:host01.example.com", target: "sr:host02.example.com"}]

    vertices = [
      %{id: "sr:host01.example.com", hostname: "host01.example.com", ip: nil},
      %{id: "sr:host03.example.com", hostname: "host03.example.com", ip: nil},
      %{id: "legacy:host04.example.com", hostname: "host04.example.com", ip: nil}
    ]

    expected = [
      %{id: "sr:host01.example.com", label: "host01.example.com"},
      %{id: "sr:host02.example.com", label: "sr:host02.example.com"},
      %{id: "sr:host03.example.com", label: "host03.example.com"}
    ]

    assert {:ok, ^expected} = AtlasSource.decode_nodes(vertices, edges)
    assert {:ok, index} = Atlas.build(expected, edges)
    assert {:ok, %{counts: %{members: 3, aggregates: 2}}} = Atlas.fetch(index)
  end

  test "vertex response parsing is deterministic and retains useful labels without a source cap" do
    rows =
      for number <- 1..10_001 do
        %{id: "sr:host#{number}.example.com", hostname: "", ip: nil}
      end

    rows = [%{id: "sr:host1.example.com", hostname: nil, ip: "192.0.2.1"} | rows]
    assert {:ok, forward} = AtlasSource.decode_nodes(rows, [])
    assert {:ok, ^forward} = AtlasSource.decode_nodes(Enum.reverse(rows), [])
    assert length(forward) == 10_001
    assert %{label: "192.0.2.1"} = Enum.find(forward, &(&1.id == "sr:host1.example.com"))

    assert %{label: "sr:host10001.example.com"} =
             Enum.find(forward, &(&1.id == "sr:host10001.example.com"))
  end

  test "malformed Dgraph responses and endpoints fail instead of publishing an empty graph" do
    for vertices <- [
          %{},
          nil,
          [:invalid],
          [%{}],
          [%{id: nil, hostname: nil, ip: nil}],
          [%{id: "", hostname: nil, ip: nil}],
          [%{id: "sr:host01.example.com", hostname: %{}, ip: nil}],
          [%{id: "sr:host01.example.com", hostname: nil, ip: []}],
          [%{id: "sr:host01.example.com", hostname: "host01.example.com", ip: nil}, %{}]
        ] do
      assert {:error, :invalid_vertex_response} = AtlasSource.decode_nodes(vertices, [])
    end

    assert {:error, :invalid_edge_endpoint} =
             AtlasSource.decode_nodes(
               [],
               [%{source: "legacy", target: "sr:host01.example.com"}]
             )
  end
end
