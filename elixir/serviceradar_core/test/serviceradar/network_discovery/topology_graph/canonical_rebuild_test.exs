defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuildTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild, as: Queries

  @moduletag :db_free

  @heartbeat_ms 3_600_000

  describe "skip_decision/4 (durable shared skip-guard)" do
    test "(a) unchanged input across restart skips the rebuild" do
      # Simulates a pod restart: persistent_term is gone, but the shared meta row
      # still holds the last-applied fingerprint. A matching current fingerprint
      # within the heartbeat window must skip the heavy rebuild.
      now = ~U[2026-06-24 12:00:00.000000Z]
      hashed_at = DateTime.add(now, -60, :second)

      assert {:skip, %{skipped: true, reason: :unchanged_topology}} =
               CanonicalRebuild.skip_decision(
                 "669:abc",
                 {"669:abc", hashed_at},
                 @heartbeat_ms,
                 now
               )
    end

    test "(b) changed input forces a rebuild" do
      now = ~U[2026-06-24 12:00:00.000000Z]
      hashed_at = DateTime.add(now, -60, :second)

      assert {:proceed, "670:def"} =
               CanonicalRebuild.skip_decision(
                 "670:def",
                 {"669:abc", hashed_at},
                 @heartbeat_ms,
                 now
               )
    end

    test "(c) nil current fingerprint fails open (query failed)" do
      now = ~U[2026-06-24 12:00:00.000000Z]
      hashed_at = DateTime.add(now, -60, :second)

      assert {:proceed, nil} =
               CanonicalRebuild.skip_decision(nil, {"669:abc", hashed_at}, @heartbeat_ms, now)
    end

    test "(c2) nil stored fingerprint fails open (fresh deploy / wiped row)" do
      now = ~U[2026-06-24 12:00:00.000000Z]

      assert {:proceed, "669:abc"} =
               CanonicalRebuild.skip_decision("669:abc", nil, @heartbeat_ms, now)
    end

    test "(d) matching hash but stale input_hashed_at proceeds (heartbeat backstop)" do
      now = ~U[2026-06-24 12:00:00.000000Z]
      # Stored fingerprint matches, but it was written longer ago than the
      # heartbeat window, so the backstop must force a rebuild.
      stale_at = DateTime.add(now, -(div(@heartbeat_ms, 1000) + 1), :second)

      assert {:proceed, "669:abc"} =
               CanonicalRebuild.skip_decision(
                 "669:abc",
                 {"669:abc", stale_at},
                 @heartbeat_ms,
                 now
               )
    end

    test "(d2) a future input_hashed_at is treated as recent and skips" do
      # Clock skew can put the stored timestamp slightly ahead of now. With a
      # matching hash that only means the topology is unchanged, so treating it as
      # "recent" (skip) is correct and harmless — a *changed* fingerprint still
      # forces a rebuild regardless of timestamp.
      now = ~U[2026-06-24 12:00:00.000000Z]
      future_at = DateTime.add(now, 60, :second)

      assert {:skip, %{skipped: true, reason: :unchanged_topology}} =
               CanonicalRebuild.skip_decision(
                 "669:abc",
                 {"669:abc", future_at},
                 @heartbeat_ms,
                 now
               )
    end
  end

  describe "rebuild_input_fingerprint_query/0" do
    test "fingerprints every existing edge label table in the rebuild input" do
      sql = Queries.rebuild_input_fingerprint_query()

      for label <- Queries.rebuild_input_edge_labels() do
        assert sql =~ "platform_graph.\"#{label}\"",
               "expected fingerprint to union platform_graph.#{label}"
      end

      # HOSTED_ON is in the rebuild's relation IN-list but has no AGE label table,
      # so it must NOT be unioned (would error the query).
      refute sql =~ "platform_graph.\"HOSTED_ON\""
    end

    test "uses agtype-correct property access (not jsonb ->>)" do
      sql = Queries.rebuild_input_fingerprint_query()

      refute sql =~ "->>"
      assert sql =~ "properties->'\"protocol\"'"
    end

    test "preserves the {count}:{md5} output shape for the unchanged binary compare" do
      sql = Queries.rebuild_input_fingerprint_query()

      assert sql =~ "count(*)::text || ':' || coalesce(md5("
      assert sql =~ "ORDER BY start_id, end_id, rel"
    end

    test "hour-buckets the timestamp fields but keeps every other field exact" do
      sql = Queries.rebuild_input_fingerprint_query()

      # last_observed_at refreshes on essentially every mapper report, so it (and
      # observed_at) MUST be bucketed to the hour (left(.., 13)) or the fingerprint
      # churns and the skip-guard never fires. Matches the upsert content_hash.
      assert sql =~ "left(coalesce((properties->'\"last_observed_at\"')::text, ''), 13)"
      assert sql =~ "left(coalesce((properties->'\"observed_at\"')::text, ''), 13)"

      # Non-timestamp fields stay exact (no bucketing) so a property change is
      # caught immediately.
      assert sql =~ "coalesce((properties->'\"protocol\"')::text, '')"
      refute sql =~ "left(coalesce((properties->'\"protocol\"')"
    end
  end

  describe "(e) fingerprint coverage parity" do
    test "fingerprint property fields exactly match the upsert content_hash fields" do
      # Adding a property field to the fingerprint OR to the upsert content_hash
      # without the other would let a change in that field be masked (or trigger a
      # needless rebuild). This literal-list equality keeps the two in lock-step:
      # if they drift, CI fails here.
      assert Queries.rebuild_input_property_fields() == Queries.content_hash_property_fields()
    end

    test "the fingerprint SQL references every content_hash property field" do
      sql = Queries.rebuild_input_fingerprint_query()

      for field <- Queries.content_hash_property_fields() do
        assert sql =~ "properties->'\"#{field}\"'",
               "fingerprint SQL is missing content_hash field #{field}"
      end
    end
  end

  describe "refresh_from_graph/1 persists the durable fingerprint" do
    test "writes input_hash + input_hashed_at and adds them to the on_conflict set" do
      assert RuntimeTopologyProjection.refresh_from_graph(
               graph: __MODULE__.EmptyGraph,
               repo: __MODULE__.CapturingRepo,
               input_hash: "669:abc"
             ) == {:ok, %{rows: 0}}

      assert_receive {:insert_all, "runtime_topology_projection_meta", [attrs], opts}
      assert attrs.input_hash == "669:abc"
      assert %DateTime{} = attrs.input_hashed_at

      assert {:replace, replace_fields} = Keyword.fetch!(opts, :on_conflict)
      assert :input_hash in replace_fields
      assert :input_hashed_at in replace_fields
    end

    test "omits the fingerprint columns when no input_hash is supplied (back-compat)" do
      assert RuntimeTopologyProjection.refresh_from_graph(
               graph: __MODULE__.EmptyGraph,
               repo: __MODULE__.CapturingRepo
             ) == {:ok, %{rows: 0}}

      assert_receive {:insert_all, "runtime_topology_projection_meta", [attrs], opts}
      refute Map.has_key?(attrs, :input_hash)
      refute Map.has_key?(attrs, :input_hashed_at)

      assert {:replace, replace_fields} = Keyword.fetch!(opts, :on_conflict)
      refute :input_hash in replace_fields
    end
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
