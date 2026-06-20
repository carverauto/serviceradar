defmodule ServiceRadar.NetworkDiscovery.RuntimeTopologyProjectionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection

  @moduletag :db_free

  test "graph_projection_query/0 reads canonical backbone plus mapper attachment evidence" do
    query = RuntimeTopologyProjection.graph_projection_query()

    assert query =~ "MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
    assert query =~ "MATCH (ai:Interface)-[r]->(bi:Interface)"
    assert query =~ "a.id STARTS WITH 'sr:'"
    assert query =~ "b.id STARTS WITH 'sr:'"
    assert query =~ "observed_at: coalesce(r.last_observed_at, r.observed_at, '')"

    assert query =~
             "toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON']"

    assert query =~ "type(r) IN ['ATTACHED_TO', 'OBSERVED_TO']"
  end

  test "projection_attrs_from_graph_rows/1 unwraps AGE row payloads into SQL projection attrs" do
    rows = [
      %{
        "row" => %{
          "local_device_id" => "sr:a",
          "neighbor_device_id" => "sr:b",
          "observed_at" => "2026-06-20T12:00:00Z",
          "evidence_class" => "direct-physical",
          "metadata" => %{
            "relation_type" => "CONNECTS_TO",
            "topology_plane" => "backbone",
            "evidence_class" => "direct-physical"
          }
        }
      }
    ]

    [attrs] = RuntimeTopologyProjection.projection_attrs_from_graph_rows(rows)

    assert attrs.topology_plane == "backbone"
    assert attrs.local_device_id == "sr:a"
    assert attrs.neighbor_device_id == "sr:b"
    assert attrs.relation_type == "CONNECTS_TO"
    assert attrs.evidence_class == "direct-physical"
    assert attrs.row["local_device_id"] == "sr:a"
    assert %DateTime{} = attrs.observed_at
  end

  test "projection_attrs_from_graph_rows/1 drops incomplete or self-loop rows" do
    rows = [
      %{"row" => %{"local_device_id" => "sr:a", "neighbor_device_id" => "sr:a"}},
      %{"row" => %{"local_device_id" => "", "neighbor_device_id" => "sr:b"}},
      %{"row" => %{"neighbor_device_id" => "sr:b"}}
    ]

    assert RuntimeTopologyProjection.projection_attrs_from_graph_rows(rows) == []
  end

  test "read_cached_links/1 trusts an initialized empty projection" do
    assert RuntimeTopologyProjection.read_cached_links(repo: __MODULE__.InitializedEmptyRepo) ==
             {:ok, []}
  end

  test "read_cached_links/1 distinguishes an uninitialized empty projection" do
    assert RuntimeTopologyProjection.read_cached_links(repo: __MODULE__.UninitializedEmptyRepo) ==
             {:error, :projection_uninitialized}
  end

  test "refresh_from_graph/1 stamps projection metadata for a zero-row refresh" do
    assert RuntimeTopologyProjection.refresh_from_graph(
             graph: __MODULE__.EmptyGraph,
             repo: __MODULE__.CapturingRepo
           ) == {:ok, %{rows: 0}}

    assert_receive {:delete_all, _query}

    assert_receive {:insert_all, "runtime_topology_projection_meta", [attrs], opts}
    assert attrs.projection_name == "runtime_topology_links"
    assert attrs.row_count == 0
    assert %DateTime{} = attrs.refreshed_at
    assert Keyword.fetch!(opts, :conflict_target) == [:projection_name]
  end

  defmodule InitializedEmptyRepo do
    @moduledoc false

    def all(_query), do: []
    def exists?(_query), do: true
  end

  defmodule UninitializedEmptyRepo do
    @moduledoc false

    def all(_query), do: []
    def exists?(_query), do: false
  end

  defmodule EmptyGraph do
    @moduledoc false

    def query(_query), do: {:ok, []}
  end

  defmodule CapturingRepo do
    @moduledoc false

    def transaction(fun), do: {:ok, fun.()}

    def delete_all(query) do
      send(self(), {:delete_all, query})
      {0, nil}
    end

    def insert_all(table, rows, opts) do
      send(self(), {:insert_all, table, rows, opts})
      {length(rows), nil}
    end
  end
end
