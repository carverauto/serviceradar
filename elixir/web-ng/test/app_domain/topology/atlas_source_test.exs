defmodule ServiceRadarWebNG.Topology.AtlasSourceTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.Atlas
  alias ServiceRadarWebNG.Topology.AtlasSource

  @moduletag :db_free

  test "AGE and Dgraph retain isolated canonical vertices and union missing relation endpoints" do
    edges = [%{source: "sr:host01.example.com", target: "sr:host02.example.com"}]

    sources = [
      {:age,
       [
         %{"id" => "sr:host01.example.com", "label" => "host01.example.com"},
         %{"id" => "sr:host03.example.com", "label" => "host03.example.com"},
         %{"id" => "legacy:host04.example.com", "label" => "host04.example.com"}
       ]},
      {:dgraph,
       %{
         "nodes" => [
           %{"device.id" => "sr:host01.example.com", "device.hostname" => "host01.example.com"},
           %{"device.id" => "sr:host03.example.com", "device.hostname" => "host03.example.com"},
           %{
             "device.id" => "legacy:host04.example.com",
             "device.hostname" => "host04.example.com"
           }
         ]
       }}
    ]

    expected = [
      %{id: "sr:host01.example.com", label: "host01.example.com"},
      %{id: "sr:host02.example.com", label: "sr:host02.example.com"},
      %{id: "sr:host03.example.com", label: "host03.example.com"}
    ]

    for {backend, response} <- sources do
      query = fn _statement -> {:ok, response} end

      assert {:ok, ^expected} = AtlasSource.fetch_nodes(edges, {backend, query})
      assert {:ok, index} = Atlas.build(expected, edges)
      assert {:ok, %{counts: %{members: 3, aggregates: 2}}} = Atlas.fetch(index)
    end
  end

  test "vertex response parsing is deterministic and retains useful labels without a source cap" do
    rows =
      for number <- 1..10_001 do
        %{"device.id" => "sr:host#{number}.example.com", "device.hostname" => ""}
      end

    rows = [%{"device.id" => "sr:host1.example.com", "device.ip" => "192.0.2.1"} | rows]
    source = fn rows -> {:dgraph, fn _statement -> {:ok, %{"nodes" => rows}} end} end
    assert {:ok, forward} = AtlasSource.fetch_nodes([], source.(rows))
    assert {:ok, ^forward} = AtlasSource.fetch_nodes([], source.(Enum.reverse(rows)))
    assert length(forward) == 10_001
    assert %{label: "192.0.2.1"} = Enum.find(forward, &(&1.id == "sr:host1.example.com"))

    assert %{label: "sr:host10001.example.com"} =
             Enum.find(forward, &(&1.id == "sr:host10001.example.com"))
  end

  test "query failures and malformed response envelopes fail instead of publishing an empty graph" do
    for {backend, response} <- [
          {:age, %{}},
          {:age, [:invalid]},
          {:age, [%{}]},
          {:dgraph, %{}},
          {:dgraph, %{"nodes" => nil}},
          {:dgraph, %{"nodes" => [%{}]}}
        ] do
      assert {:error, :invalid_vertex_response} =
               AtlasSource.fetch_nodes([], {backend, fn _statement -> {:ok, response} end})
    end

    assert {:error, :unavailable} =
             AtlasSource.fetch_nodes([], {:age, fn _ -> {:error, :unavailable} end})

    assert {:error, :invalid_vertex_response} =
             AtlasSource.fetch_nodes([], {:age, fn _ -> :ok end})

    assert {:error, {:vertex_read_exit, :timeout}} =
             AtlasSource.fetch_nodes([], {:age, fn _ -> exit(:timeout) end})

    assert {:error, {:vertex_read_failed, %RuntimeError{}}} =
             AtlasSource.fetch_nodes([], {:age, fn _ -> raise "unavailable" end})

    assert {:error, :invalid_edge_endpoint} =
             AtlasSource.fetch_nodes(
               [%{source: "legacy", target: "sr:host01.example.com"}],
               {:age, fn _ -> {:ok, []} end}
             )
  end
end
