defmodule ServiceRadarWebNG.Topology.RuntimeGraphTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNG.Topology.RuntimeGraph

  test "topology_links_query/0 reads canonical backend relation" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "coalesce(r.relation_type, type(r)) IN ['CONNECTS_TO', 'ATTACHED_TO']"
    assert query =~ "ORDER BY"
  end

  test "topology_links_query/0 returns relation metadata and interface attribution" do
    query = RuntimeGraph.topology_links_query()

    assert query =~ "relation_type: coalesce(r.relation_type, type(r))"
    assert query =~ "local_if_name: coalesce(r.local_if_name, '')"
    assert query =~ "local_if_index: r.local_if_index"
  end
end
