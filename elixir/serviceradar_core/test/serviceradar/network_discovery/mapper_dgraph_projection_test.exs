defmodule ServiceRadar.NetworkDiscovery.MapperDgraphProjectionTest do
  @moduledoc """
  End-to-end mapper topology projection against a live Dgraph scratch
  namespace.

  Restores the graph-state half of `mapper_graph_ingestion_test.exs` that
  the AGE retirement (#6306) removed: that module still proves CNPG
  evidence persistence, and this one proves the same mapper payloads land
  in Dgraph as evidence + canonical edges, read back through
  `ServiceRadar.Dgraph.query_canonical_edges/0`. Payloads mirror what
  go/pkg/mapper emits; every id and address is invented.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Links
  alias ServiceRadar.Repo
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

  setup do
    clear_report_fingerprints()
    on_exit(&clear_report_fingerprints/0)
    Application.put_env(:serviceradar_core, :mapper_topology_edge_stale_minutes, 180)
    :ok
  end

  test "LLDP ingest projects a canonical backbone edge with interface identity" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-dg-lldp-a"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "LLDP",
        "agent_id" => "agent-it-dgraph",
        "gateway_id" => "agent-it-dgraph",
        "partition" => "default",
        "local_device_id" => "sr:it-dg-lldp-a",
        "local_device_ip" => "198.51.100.21",
        "local_if_index" => 10,
        "local_if_name" => "eth0",
        "neighbor_device_id" => "sr:it-dg-lldp-b",
        "neighbor_port_id" => "Gi0/1",
        "neighbor_system_name" => "dg-lldp-b",
        "neighbor_mgmt_addr" => "198.51.100.22",
        "metadata" => %{"source" => "lldp", "evidence_class" => "direct-physical"}
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    edges = canonical_edges()

    assert edge = find_pair(edges, "sr:it-dg-lldp-a", "sr:it-dg-lldp-b"),
           "expected canonical edge for the LLDP pair in #{inspect(edges)}"

    assert edge.evidence_class == "direct-physical"
    assert edge.if_name_ab == "eth0" or edge.if_name_ba == "eth0"
    assert edge.link_key != ""
  end

  test "wireguard ingest projects a canonical logical edge" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-dg-wg-a"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "wireguard-derived",
        "agent_id" => "agent-it-dgraph",
        "gateway_id" => "agent-it-dgraph",
        "partition" => "default",
        "local_device_id" => "sr:it-dg-wg-a",
        "local_device_ip" => "203.0.113.21",
        "local_if_name" => "wg0",
        "neighbor_device_id" => "sr:it-dg-wg-b",
        "neighbor_port_id" => "wg0",
        "neighbor_port_descr" => "wireguard",
        "neighbor_system_name" => "dg-wg-b",
        "neighbor_mgmt_addr" => "203.0.113.22",
        "metadata" => %{
          "source" => "wireguard-derived",
          "evidence_class" => "direct-logical",
          "relation_family" => "LOGICAL_PEER",
          "confidence_tier" => "high",
          "confidence_score" => 95
        }
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    assert edge = find_pair(canonical_edges(), "sr:it-dg-wg-a", "sr:it-dg-wg-b")
    assert edge.evidence_class == "direct-logical"
  end

  test "LLDP without interface identity is gated out of the graph but kept as CNPG evidence" do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    purge_topology_rows(["sr:it-dg-gated-a"])

    payload = [
      %{
        "timestamp" => now,
        "protocol" => "LLDP",
        "agent_id" => "agent-it-dgraph",
        "gateway_id" => "agent-it-dgraph",
        "partition" => "default",
        "local_device_id" => "sr:it-dg-gated-a",
        "local_device_ip" => "198.51.100.31",
        "neighbor_device_id" => "sr:it-dg-gated-b",
        "neighbor_port_id" => "Gi0/2",
        "neighbor_system_name" => "dg-gated-b",
        "neighbor_mgmt_addr" => "198.51.100.32",
        "metadata" => %{"source" => "lldp", "evidence_class" => "direct-physical"}
      }
    ]

    assert :ok = MapperResultsIngestor.ingest_topology(Jason.encode!(payload), %{})

    # The strict-ifindex policy keeps this evidence out of Dgraph...
    refute find_pair(canonical_edges(), "sr:it-dg-gated-a", "sr:it-dg-gated-b")

    # ...while the CNPG evidence row still persists, so the gate is the
    # projection policy, not an ingest rejection.
    assert [%{"protocol" => "LLDP"}] = topology_rows("sr:it-dg-gated-a")
  end

  defp canonical_edges do
    assert {:ok, edges} = Dgraph.query_canonical_edges()
    edges
  end

  defp find_pair(edges, a, b) do
    Enum.find(edges, fn edge ->
      MapSet.new([edge.source, edge.target]) == MapSet.new([a, b])
    end)
  end

  defp purge_topology_rows(local_device_ids) do
    SQL.query!(
      Repo,
      "DELETE FROM platform.mapper_topology_links WHERE local_device_id = ANY($1)",
      [local_device_ids]
    )

    :ok
  end

  defp topology_rows(local_device_id) do
    %Postgrex.Result{rows: rows, columns: columns} =
      SQL.query!(
        Repo,
        "SELECT protocol FROM platform.mapper_topology_links WHERE local_device_id = $1",
        [local_device_id]
      )

    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp clear_report_fingerprints do
    Enum.each(:persistent_term.get(), fn
      {{Links, :report_fingerprint, _scope} = key, _value} ->
        :persistent_term.erase(key)

      _other ->
        :ok
    end)

    :ok
  end
end
