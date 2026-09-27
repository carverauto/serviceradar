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

  test "graph_projection_query/0 projects inferred-segment device attachments as attachment rows" do
    query = RuntimeTopologyProjection.graph_projection_query()

    assert query =~ "toUpper(coalesce(r.relation_type, '')) = 'ATTACHED_TO'"
    assert query =~ "toLower(coalesce(r.evidence_class, '')) = 'inferred-segment'"
    assert query =~ "evidence_class: coalesce(r.evidence_class, 'inferred-segment')"

    assert query =~ "topology_plane: 'attachment'"

    # the inferred-segment branch must be its own UNION part with the same row shape
    assert query =~ "UNION ALL\nMATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)"
  end

  test "graph_projection_query/0 totally orders boundary ties by stable source identities" do
    query = RuntimeTopologyProjection.graph_projection_query()

    canonical_order = [
      "coalesce(r.last_observed_at, r.observed_at) DESC",
      "a.id ASC",
      "b.id ASC",
      "toUpper(coalesce(r.relation_type, type(r), '')) ASC",
      "toLower(coalesce(r.evidence_class, '')) ASC",
      "coalesce(r.local_if_index, -1) ASC",
      "coalesce(r.local_if_name, '') ASC",
      "coalesce(r.neighbor_if_index, -1) ASC",
      "coalesce(r.neighbor_if_name, '') ASC",
      "coalesce(r.protocol, r.source, 'unknown') ASC",
      "coalesce(r.link_key, '') ASC"
    ]

    interface_order = [
      "coalesce(r.last_observed_at, r.observed_at) DESC",
      "ai.device_id ASC",
      "bi.device_id ASC",
      "type(r) ASC",
      "toLower(coalesce(r.evidence_class, '')) ASC",
      "coalesce(ai.ifindex, -1) ASC",
      "coalesce(ai.name, '') ASC",
      "coalesce(bi.ifindex, -1) ASC",
      "coalesce(bi.name, '') ASC",
      "coalesce(r.protocol, r.source, 'unknown') ASC",
      "coalesce(ai.id, '') ASC",
      "coalesce(bi.id, '') ASC"
    ]

    # At a LIMIT boundary, canonical links may tie on every projected attribute above but
    # still differ by link_key; mapper links may likewise differ only by interface identity.
    assert [^canonical_order, ^interface_order, ^canonical_order] = bounded_order_keys(query)
  end

  test "projection_attrs_from_graph_rows/1 maps inferred-segment device rows to the attachment plane" do
    rows = [
      %{
        "row" => %{
          "local_device_id" => "sr:endpoint",
          "neighbor_device_id" => "sr:switch",
          "observed_at" => "",
          "evidence_class" => "inferred-segment",
          "metadata" => %{
            "relation_type" => "ATTACHED_TO",
            "topology_plane" => "attachment",
            "evidence_class" => "inferred-segment"
          }
        }
      }
    ]

    [attrs] = RuntimeTopologyProjection.projection_attrs_from_graph_rows(rows)

    assert attrs.topology_plane == "attachment"
    assert attrs.relation_type == "ATTACHED_TO"
    assert attrs.evidence_class == "inferred-segment"
    assert attrs.local_device_id == "sr:endpoint"
    assert attrs.neighbor_device_id == "sr:switch"
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

  test "read_cached_links/1 totally orders content ties before applying its limit" do
    assert RuntimeTopologyProjection.read_cached_links(repo: __MODULE__.CapturingRepo) ==
             {:ok, []}

    assert_receive {:all, %Ecto.Query{order_bys: [%Ecto.Query.ByExpr{expr: order_by}]}}

    assert Enum.map(order_by, &cached_order_key/1) == [
             {:asc, :topology_plane_rank},
             {:desc_nulls_last, :observed_at},
             {:desc, :inserted_at},
             {:asc, :local_device_id},
             {:asc, :neighbor_device_id},
             {:asc, :relation_type},
             {:asc, :evidence_class},
             {:asc, {:text, :row}},
             {:asc, :id}
           ]
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

    def all(query) do
      send(self(), {:all, query})
      []
    end

    def exists?(_query), do: true

    def delete_all(query) do
      send(self(), {:delete_all, query})
      {0, nil}
    end

    def insert_all(table, rows, opts) do
      send(self(), {:insert_all, table, rows, opts})
      {length(rows), nil}
    end
  end

  defp bounded_order_keys(query) do
    query
    |> String.split("ORDER BY ")
    |> tl()
    |> Enum.map(fn bounded_query ->
      [order_keys, _rest] = String.split(bounded_query, ~r/\n\s*LIMIT /, parts: 2)

      order_keys
      |> String.split(~r/,\s*\n/)
      |> Enum.map(&String.trim/1)
    end)
  end

  defp cached_order_key({direction, field_ref}) do
    {direction, cached_order_field(field_ref)}
  end

  defp cached_order_field({{:., _, [{:&, _, [0]}, field]}, _, []}), do: field

  defp cached_order_field({:fragment, _, [{:raw, "CASE "} | _]}), do: :topology_plane_rank

  defp cached_order_field({:fragment, _, [{:raw, ""}, {:expr, field_ref}, {:raw, "::text"}]}) do
    {:text, cached_order_field(field_ref)}
  end
end
