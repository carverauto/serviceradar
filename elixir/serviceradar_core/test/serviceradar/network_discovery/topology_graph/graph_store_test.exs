defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStoreTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.HorizonTopologyConsumer
  alias ServiceRadar.NetworkConfig.Projector
  alias ServiceRadar.NetworkDiscovery.TopologyGraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.GraphStore.Dgraph

  defmodule FakeGraphStore do
    @moduledoc false
    @behaviour GraphStore

    @impl true
    def writable?, do: true

    @impl true
    def upsert_interfaces(payloads), do: notify(:upsert_interfaces, payloads, :ok)

    @impl true
    def upsert_links(projected), do: notify(:upsert_links, projected, :ok)

    @impl true
    def upsert_managed_by(child, mgmt), do: notify(:upsert_managed_by, {child, mgmt}, :ok)

    @impl true
    def upsert_mtr_path(attrs), do: notify(:upsert_mtr_path, attrs, :ok)

    @impl true
    def upsert_risk_summary(uid, summary), do: notify(:upsert_risk_summary, {uid, summary}, :ok)

    @impl true
    def project_config_facts(payloads), do: notify(:project_config_facts, payloads, :ok)

    @impl true
    def prune_stale(cutoff, kinds), do: notify(:prune_stale, {cutoff, kinds}, :ok)

    @impl true
    def upsert_external_topology(snapshot, opts),
      do:
        notify(
          :upsert_external_topology,
          {snapshot, opts},
          {:ok,
           %{
             nodes_upserted: length(snapshot.nodes),
             edges_upserted: length(snapshot.edges),
             edges_skipped: 0
           }}
        )

    @impl true
    def upsert_external_status(patch, opts),
      do: notify(:upsert_external_status, {patch, opts}, :ok)

    @impl true
    def prune_stale_external(cutoff, opts),
      do: notify(:prune_stale_external, {cutoff, opts}, {:ok, 3})

    @impl true
    def blast_radius(seed, opts),
      do:
        notify(
          :blast_radius,
          {seed, opts},
          {:ok,
           %{"seed_id" => seed, "internal_devices" => [%{"id" => "sr:edge-01"}], "edges" => []}}
        )

    @impl true
    def shared_fate_spofs(opts),
      do: notify(:shared_fate_spofs, opts, {:ok, [%{"id" => "asn:64512", "target_count" => 3}]})

    @impl true
    def customer_cone_impact(asn, opts),
      do:
        notify(
          :customer_cone_impact,
          {asn, opts},
          {:ok, %{"asn_id" => to_string(asn), "prefixes" => [%{"id" => "198.51.100.0/24"}]}}
        )

    @impl true
    def multi_hop_trace(query, opts),
      do:
        notify(
          :multi_hop_trace,
          {query, opts},
          {:ok, %{"found" => true, "hops" => 2, "nodes" => [], "edges" => []}}
        )

    @impl true
    def egress_topology(opts),
      do:
        notify(
          :egress_topology,
          opts,
          {:ok,
           %{
             "max_hops" => 4,
             "truncated" => false,
             "egress_devices" => [],
             "external_nodes" => [],
             "edges" => []
           }}
        )

    defp notify(op, payload, result) do
      send(self(), {:graph_store_call, op, payload})
      result
    end
  end

  setup do
    prev = Application.get_env(:serviceradar_core, TopologyGraph)

    on_exit(fn ->
      if is_nil(prev) do
        Application.delete_env(:serviceradar_core, TopologyGraph)
      else
        Application.put_env(:serviceradar_core, TopologyGraph, prev)
      end
    end)

    :ok
  end

  test "defaults to GraphStore.Dgraph and swaps cleanly via application env" do
    Application.delete_env(:serviceradar_core, TopologyGraph)
    assert GraphStore.adapter() == Dgraph

    Application.put_env(:serviceradar_core, TopologyGraph, graph_store: FakeGraphStore)
    assert GraphStore.adapter() == FakeGraphStore
  end

  test "TopologyGraph delegates external topology and query operations through configured GraphStore" do
    Application.put_env(:serviceradar_core, TopologyGraph, graph_store: FakeGraphStore)

    snap = %{
      generated_at: "2026-11-25T00:00:00Z",
      ttl_secs: 900,
      nodes: [%{id: "asn:64512"}],
      edges: []
    }

    assert {:ok, %{nodes_upserted: 1}} = TopologyGraph.upsert_external_topology(snap)
    assert_receive {:graph_store_call, :upsert_external_topology, {^snap, []}}

    patch = %{entity_id: "198.51.100.0/24", rtbh_active: true}
    assert :ok = TopologyGraph.upsert_external_status(patch)
    assert_receive {:graph_store_call, :upsert_external_status, {^patch, []}}

    assert {:ok, 3} = TopologyGraph.prune_stale_external("2026-11-25T00:00:00Z")
    assert_receive {:graph_store_call, :prune_stale_external, {"2026-11-25T00:00:00Z", []}}

    assert {:ok, %{"seed_id" => "asn:64512"}} =
             TopologyGraph.blast_radius("asn:64512", max_hops: 3)

    assert_receive {:graph_store_call, :blast_radius, {"asn:64512", [max_hops: 3]}}

    assert {:ok, [%{"id" => "asn:64512"}]} = TopologyGraph.shared_fate_spofs(min_targets: 2)
    assert_receive {:graph_store_call, :shared_fate_spofs, [min_targets: 2]}

    assert {:ok, %{"asn_id" => "64512"}} = TopologyGraph.customer_cone_impact(64_512, limit: 10)
    assert_receive {:graph_store_call, :customer_cone_impact, {64_512, [limit: 10]}}

    assert {:ok, %{"found" => true}} =
             TopologyGraph.multi_hop_trace(%{from: "sr:edge-01", to: "saas:api.example"},
               max_hops: 5
             )

    assert_receive {:graph_store_call, :multi_hop_trace,
                    {%{from: "sr:edge-01", to: "saas:api.example"}, [max_hops: 5]}}

    assert {:ok, %{"egress_devices" => []}} =
             TopologyGraph.egress_topology(max_hops: 3, limit: 25)

    assert_receive {:graph_store_call, :egress_topology, [max_hops: 3, limit: 25]}

    config_facts = %{device_uid: "sr:edge-01", interfaces: [], prefixes: []}
    assert :ok = TopologyGraph.project_config_facts(config_facts)
    assert_receive {:graph_store_call, :project_config_facts, ^config_facts}

    assert :ok =
             Projector.project("sr:edge-01", "rev-1", [
               %{if_name: "eth0", ipv4_prefix: "192.0.2.0/24"}
             ])

    assert_receive {:graph_store_call, :project_config_facts, %{device_uid: "sr:edge-01"}}

    now = ~U[2026-11-25 00:16:00Z]
    assert :ok = HorizonTopologyConsumer.prune_once(now)
    assert_receive {:graph_store_call, :prune_stale_external, {"2026-11-25T00:16:00Z", []}}
  end
end
