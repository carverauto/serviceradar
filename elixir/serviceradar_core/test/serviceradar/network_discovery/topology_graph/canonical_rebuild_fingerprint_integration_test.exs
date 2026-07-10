defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuildFingerprintIntegrationTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Graph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild, as: Queries
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration
  @moduletag sandbox: :unboxed

  @fixture_ids ["sr:fingerprint-interface-a", "sr:fingerprint-interface-b"]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "durable fingerprint changes when endpoint Interface properties change" do
    on_exit(&cleanup_fixture/0)

    assert :ok = Graph.execute(fixture_cypher())
    initial = fingerprint!()

    assert :ok =
             Graph.execute(
               "MATCH (i:Interface {id: 'sr:fingerprint-interface-a'}) SET i.name = 'uplink-renamed'"
             )

    renamed = fingerprint!()
    refute renamed == initial

    assert :ok =
             Graph.execute(
               "MATCH (i:Interface {id: 'sr:fingerprint-interface-a'}) SET i.ifindex = 101"
             )

    reindexed = fingerprint!()
    refute reindexed == renamed
  end

  defp fingerprint! do
    assert {:ok, %Postgrex.Result{rows: [[fingerprint]]}} =
             Repo.query(Queries.rebuild_input_fingerprint_query(), [])

    fingerprint
  end

  defp fixture_cypher do
    """
    MERGE (a:Interface {id: 'sr:fingerprint-interface-a'})
    SET a.device_id = 'sr:fingerprint-device-a', a.name = 'uplink', a.ifindex = 100
    MERGE (b:Interface {id: 'sr:fingerprint-interface-b'})
    SET b.device_id = 'sr:fingerprint-device-b', b.name = 'downlink', b.ifindex = 200
    MERGE (a)-[:CONNECTS_TO]->(b)
    MERGE (a)-[:LOGICAL_PEER]->(b)
    MERGE (a)-[:INFERRED_TO]->(b)
    MERGE (a)-[:ATTACHED_TO]->(b)
    MERGE (a)-[:OBSERVED_TO]->(b)
    """
  end

  defp cleanup_fixture do
    quoted_ids = Enum.map_join(@fixture_ids, ", ", &("'" <> Graph.escape(&1) <> "'"))
    assert :ok = Graph.execute("MATCH (n) WHERE n.id IN [#{quoted_ids}] DETACH DELETE n")
  end
end
