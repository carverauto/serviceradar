defmodule ServiceRadar.Observability.MtrGraphIntegrationTest do
  @moduledoc """
  End-to-end MTR graph projection against a live Dgraph scratch namespace.

  Dgraph port of the AGE-era `mtr_graph_integration_test.exs` that #6306
  deleted: a trace becomes a chain of MTR_PATH edges carrying the far hop's
  metrics, re-projection is idempotent, non-responding hops are skipped, and
  stale pruning removes only edges older than the cutoff. Assertions read
  back through `ServiceRadar.Dgraph.query_mtr_paths/1`, the same read the
  topology overlay uses. All addresses are invented documentation-range IPs.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphPersist
  alias ServiceRadar.Observability.MtrGraph
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.DgraphScratch

  @moduletag :integration
  # Three-state fixture gating (see DgraphScratch): unconfigured skips,
  # partial fails loudly in setup_all, configured runs against dgraph-ci.
  @moduletag skip: DgraphScratch.fixture_state() == :unconfigured

  setup_all do
    TestSupport.start_core!()
    DgraphScratch.setup_scratch()
  end

  test "project_traces creates an MTR_PATH chain with far-hop metrics" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{
              "hop_number" => 1,
              "addr" => "192.0.2.1",
              "hostname" => "gw.example",
              "avg_us" => 480,
              "loss_pct" => 0.0,
              "jitter_us" => 20
            },
            %{
              "hop_number" => 2,
              "addr" => "198.51.100.1",
              "hostname" => "transit.example",
              "avg_us" => 12_000,
              "loss_pct" => 10.0,
              "jitter_us" => 500
            },
            %{
              "hop_number" => 3,
              "addr" => "203.0.113.9",
              "hostname" => "dest.example",
              "avg_us" => 15_000,
              "loss_pct" => 0.0,
              "jitter_us" => 100
            }
          ]
        }
      }
    ]

    assert :ok = MtrGraph.project_traces(results, %{agent_id: "agent-mtr-chain"})

    paths = mtr_paths()

    assert edge =
             find_edge(paths, "192.0.2.1", "198.51.100.1"),
           "expected MTR_PATH 192.0.2.1 -> 198.51.100.1 in #{inspect(paths)}"

    # The far hop's measurements describe the segment that ends there.
    assert edge.avg_us == 12_000
    assert edge.loss_pct == 10.0
    assert edge.jitter_us == 500
    assert edge.from_hop == 1
    assert edge.to_hop == 2
    assert edge.agent_id == "agent-mtr-chain"

    assert second = find_edge(paths, "198.51.100.1", "203.0.113.9")
    assert second.avg_us == 15_000
    assert second.from_hop == 2
    assert second.to_hop == 3

    # No edge skips a hop: the chain is consecutive pairs only.
    refute find_edge(paths, "192.0.2.1", "203.0.113.9")
  end

  test "project_traces is idempotent and skips non-responding hops" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "192.0.2.41", "avg_us" => 300},
            %{"hop_number" => 2, "addr" => "", "avg_us" => 0},
            %{"hop_number" => 3, "addr" => nil, "avg_us" => 0},
            %{"hop_number" => 4, "addr" => "203.0.113.41", "avg_us" => 9_000}
          ]
        }
      }
    ]

    status = %{agent_id: "agent-mtr-idem"}
    assert :ok = MtrGraph.project_traces(results, status)
    assert :ok = MtrGraph.project_traces(results, status)

    edges =
      Enum.filter(mtr_paths(), fn path ->
        path.source_addr == "192.0.2.41" or path.target_addr == "203.0.113.41"
      end)

    # One edge joins the two responding hops, exactly once, with the far
    # hop's original hop number preserved across the silent hops.
    assert [edge] = edges
    assert edge.source_addr == "192.0.2.41"
    assert edge.target_addr == "203.0.113.41"
    assert edge.to_hop == 4

    # A trace with fewer than two responding hops projects nothing.
    single = [
      %{
        "trace" => %{
          "hops" => [%{"hop_number" => 1, "addr" => "198.51.100.77", "avg_us" => 100}]
        }
      }
    ]

    assert :ok = MtrGraph.project_traces(single, status)
    refute Enum.any?(mtr_paths(), &(&1.source_addr == "198.51.100.77"))
  end

  test "pruning removes only MTR_PATH edges older than the cutoff" do
    results = [
      %{
        "trace" => %{
          "hops" => [
            %{"hop_number" => 1, "addr" => "192.0.2.81", "avg_us" => 100},
            %{"hop_number" => 2, "addr" => "203.0.113.81", "avg_us" => 200}
          ]
        }
      }
    ]

    assert :ok = MtrGraph.project_traces(results, %{agent_id: "agent-mtr-prune"})
    assert find_edge(mtr_paths(), "192.0.2.81", "203.0.113.81")

    # Default 24h pruning keeps the just-observed edge.
    assert :ok = MtrGraph.prune_stale_edges()
    assert find_edge(mtr_paths(), "192.0.2.81", "203.0.113.81")

    # A cutoff ahead of the observation removes it.
    future =
      DateTime.utc_now() |> DateTime.shift(hour: 1) |> DateTime.to_iso8601()

    assert :ok = DgraphPersist.prune_stale(future, ["MTR_PATH"])
    refute find_edge(mtr_paths(), "192.0.2.81", "203.0.113.81")
  end

  defp mtr_paths do
    assert {:ok, paths} = Dgraph.query_mtr_paths(100)
    paths
  end

  defp find_edge(paths, source_addr, target_addr) do
    Enum.find(paths, fn path ->
      path.source_addr == source_addr and path.target_addr == target_addr
    end)
  end
end
