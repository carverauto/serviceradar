defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuildTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild, as: Queries

  @moduletag :db_free

  @heartbeat_ms 3_600_000

  # Demo outage shape (fj #4378): evidence froze 2026-06-25, 7-day cutoff
  # crossed it 2026-07-02, prune wiped all 675 canonical edges.
  @stale_cutoff "2026-07-02T07:51:15Z"
  @frozen_evidence_max "2026-06-25T07:51:15Z"
  @fresh_evidence_max "2026-07-04T09:00:00Z"

  @doc false
  def forward_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp unique_condition(tag) do
    condition = {:canonical_rebuild_test, tag, System.unique_integer([:positive])}
    on_exit(fn -> HealthConditions.clear(condition) end)
    condition
  end

  defp attach_telemetry(event) do
    handler_id = "canonical-rebuild-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.forward_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

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
      assert sql =~ "edge.properties->'\"protocol\"'"
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
      assert sql =~ "left(coalesce((edge.properties->'\"last_observed_at\"')::text, ''), 13)"
      assert sql =~ "left(coalesce((edge.properties->'\"observed_at\"')::text, ''), 13)"

      # Non-timestamp fields stay exact (no bucketing) so a property change is
      # caught immediately.
      assert sql =~ "coalesce((edge.properties->'\"protocol\"')::text, '')"
      refute sql =~ "left(coalesce((edge.properties->'\"protocol\"')"
    end

    test "fingerprints mutable properties from both endpoint Interface vertices" do
      sql = Queries.rebuild_input_fingerprint_query()

      assert sql =~
               "LEFT JOIN platform_graph.\"Interface\" start_interface ON start_interface.id = edge.start_id"

      assert sql =~
               "LEFT JOIN platform_graph.\"Interface\" end_interface ON end_interface.id = edge.end_id"

      for endpoint <- ["start_interface", "end_interface"], field <- ["name", "ifindex"] do
        assert sql =~ "#{endpoint}.properties->'\"#{field}\"'",
               "fingerprint SQL is missing #{endpoint}.#{field}"
      end
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
        assert sql =~ "edge.properties->'\"#{field}\"'",
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

  describe "starvation_check/5 (starvation guard, fj #4378)" do
    test "(a) frozen evidence with canonical edges still present is starved (freshness term)" do
      # First fatal run: all evidence is older than the cutoff, so the upsert
      # matched nothing, but the 675 stale canonical edges still exist — the
      # count term alone would sail past this and the prune would delete the
      # entire canonical set. The freshness term must catch it.
      assert :starved =
               CanonicalRebuild.starvation_check(
                 675,
                 675,
                 @frozen_evidence_max,
                 @stale_cutoff,
                 0
               )
    end

    test "zero canonical edges after upsert with evidence present is starved (post-wipe steady state)" do
      assert :starved =
               CanonicalRebuild.starvation_check(0, 675, @frozen_evidence_max, @stale_cutoff, 0)
    end

    test "zero upsert with evidence is starved even when evidence freshness is unknown" do
      assert :starved = CanonicalRebuild.starvation_check(0, 675, nil, @stale_cutoff, 0)
    end

    test "zero upsert with fresh evidence is still starved via the count term" do
      # Evidence is arriving but nothing survives to the canonical graph
      # (e.g. endpoint resolution rejects everything): pruning would still
      # zero the graph for a non-topology reason.
      assert :starved =
               CanonicalRebuild.starvation_check(0, 675, @fresh_evidence_max, @stale_cutoff, 0)
    end

    test "(b) fresh evidence with a healthy upsert is not starved (normal topology change)" do
      assert :ok ==
               CanonicalRebuild.starvation_check(
                 675,
                 675,
                 @fresh_evidence_max,
                 @stale_cutoff,
                 0
               )
    end

    test "no mapper evidence at all is not starved (nothing to starve on)" do
      assert :ok == CanonicalRebuild.starvation_check(0, 0, nil, @stale_cutoff, 0)
    end

    test "unknown evidence freshness alone does not starve a healthy upsert" do
      assert :ok == CanonicalRebuild.starvation_check(675, 675, nil, @stale_cutoff, 0)
    end

    test "configurable floor widens the zero-only count trigger" do
      assert :starved =
               CanonicalRebuild.starvation_check(3, 675, @fresh_evidence_max, @stale_cutoff, 5)

      assert :starved =
               CanonicalRebuild.starvation_check(5, 675, @fresh_evidence_max, @stale_cutoff, 5)

      assert :ok ==
               CanonicalRebuild.starvation_check(6, 675, @fresh_evidence_max, @stale_cutoff, 5)
    end
  end

  describe "prune_guard_check/4 (mass-deletion guardrail, fj #4378)" do
    test "(c) refuses a single pass deleting more than the max fraction" do
      # The demo wipe: every canonical edge was a prune candidate.
      assert {:refuse, :mass_deletion} = CanonicalRebuild.prune_guard_check(675, 675, 0.5, false)
      assert {:refuse, :mass_deletion} = CanonicalRebuild.prune_guard_check(6, 10, 0.5, false)
    end

    test "allows pruning at or below the max fraction" do
      assert :allow == CanonicalRebuild.prune_guard_check(5, 10, 0.5, false)
      assert :allow == CanonicalRebuild.prune_guard_check(1, 10, 0.5, false)
    end

    test "zero candidates is always allowed (deletes nothing)" do
      assert :allow == CanonicalRebuild.prune_guard_check(0, 0, 0.5, false)
      assert :allow == CanonicalRebuild.prune_guard_check(0, 675, 0.5, false)
    end

    test "operator override bypasses the guardrail" do
      assert :allow == CanonicalRebuild.prune_guard_check(675, 675, 0.5, true)
    end

    test "an unavailable candidate count fails closed" do
      assert {:refuse, :candidate_count_unavailable} =
               CanonicalRebuild.prune_guard_check(nil, 675, 0.5, false)
    end
  end

  describe "report_starvation/5 (starved signal)" do
    test "(a) emits starved telemetry with counts + freshness and records the unhealthy condition" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :starved])
      condition = unique_condition(:starved)

      counts = %{before_edges: 675, mapper_evidence_edges: 675, after_upsert_edges: 675}

      log =
        capture_log(fn ->
          assert :ok =
                   CanonicalRebuild.report_starvation(
                     counts,
                     @stale_cutoff,
                     @frozen_evidence_max,
                     0,
                     condition: condition
                   )
        end)

      assert log =~ "Canonical topology rebuild starved"

      assert_receive {:telemetry, [:serviceradar, :topology, :canonical_rebuild, :starved],
                      measurements, metadata}

      assert measurements.before_edges == 675
      assert measurements.mapper_evidence_edges == 675
      assert measurements.after_upsert_edges == 675
      assert metadata.stale_cutoff == @stale_cutoff
      assert metadata.evidence_max_last_observed_at == @frozen_evidence_max
      assert HealthConditions.unhealthy?(condition)
    end

    test "repeated starvation deduplicates into one ongoing condition" do
      condition = unique_condition(:starved_repeat)
      counts = %{before_edges: 675, mapper_evidence_edges: 675, after_upsert_edges: 675}

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            assert :ok =
                     CanonicalRebuild.report_starvation(
                       counts,
                       @stale_cutoff,
                       @frozen_evidence_max,
                       0,
                       condition: condition
                     )
          end
        end)

      assert log =~ "Canonical topology rebuild starved"
      assert %{occurrences: 3} = HealthConditions.get(condition)
    end
  end

  describe "report_prune_refusal/5 (guardrail signal)" do
    test "(c) emits prune_refused telemetry with candidate counts and the configured fraction" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :prune_refused])

      counts = %{before_edges: 675, mapper_evidence_edges: 675, after_upsert_edges: 675}

      log =
        capture_log(fn ->
          assert :ok =
                   CanonicalRebuild.report_prune_refusal(
                     :mass_deletion,
                     675,
                     counts,
                     @stale_cutoff,
                     0.5
                   )
        end)

      assert log =~ "Canonical topology stale prune refused"

      assert_receive {:telemetry, [:serviceradar, :topology, :canonical_rebuild, :prune_refused],
                      measurements, metadata}

      assert measurements.prune_candidates == 675
      assert measurements.before_edges == 675
      assert metadata.reason == :mass_deletion
      assert metadata.max_fraction == 0.5
      assert metadata.stale_cutoff == @stale_cutoff
    end
  end

  describe "finalize_self_heal_outcome/5 (honest self-heal, fj #4378)" do
    test "(d) a zero-edge outcome with evidence present is a failure, not completion" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :self_heal_failed])
      condition = unique_condition(:self_heal_failed)

      log =
        capture_log(fn ->
          result =
            CanonicalRebuild.finalize_self_heal_outcome(0, 0, 675, 1, condition: condition)

          assert result.status == :failed
          assert result.reason == :canonical_edges_below_threshold
          assert result.after == 0
        end)

      assert log =~ "Canonical topology self-heal FAILED"

      assert_receive {:telemetry,
                      [:serviceradar, :topology, :canonical_rebuild, :self_heal_failed],
                      measurements, metadata}

      assert measurements.after_edges == 0
      assert measurements.mapper_evidence_edges == 675
      assert metadata.reason == :canonical_edges_below_threshold
      assert HealthConditions.unhealthy?(condition)
    end

    test "repeated identical failures deduplicate into one ongoing condition" do
      condition = unique_condition(:self_heal_dedup)

      log =
        capture_log(fn ->
          for _ <- 1..3 do
            assert %{status: :failed} =
                     CanonicalRebuild.finalize_self_heal_outcome(0, 0, 675, 1,
                       condition: condition
                     )
          end
        end)

      assert log =~ "Canonical topology self-heal FAILED"
      assert %{occurrences: 3} = HealthConditions.get(condition)
    end

    test "(e) recovery above the threshold completes and clears the condition" do
      condition = unique_condition(:self_heal_recovery)

      log =
        capture_log(fn ->
          assert %{status: :failed} =
                   CanonicalRebuild.finalize_self_heal_outcome(0, 0, 675, 1, condition: condition)
        end)

      assert log =~ "Canonical topology self-heal FAILED"
      assert HealthConditions.unhealthy?(condition)

      recovery_log =
        capture_log([level: :info], fn ->
          result =
            CanonicalRebuild.finalize_self_heal_outcome(0, 42, 675, 1, condition: condition)

          assert result.status == :completed
          assert result.after == 42
        end)

      assert recovery_log =~ "Canonical topology self-heal recovered canonical edges"
      refute HealthConditions.unhealthy?(condition)
    end
  end

  describe "prune guard queries (fj #4378)" do
    test "prune candidate count query mirrors the prune WHERE clause exactly" do
      prune = Queries.canonical_rebuild_prune_query(@stale_cutoff)
      count = Queries.canonical_rebuild_prune_candidate_count_query(@stale_cutoff)

      assert count == String.replace(prune, "DELETE r", "RETURN {count: count(r)}")
    end

    test "evidence freshness query covers the same relation set as the evidence count" do
      freshness = Queries.mapper_evidence_freshness_query()
      count = Queries.mapper_evidence_edge_count_query()

      assert [_, in_list] = Regex.run(~r/type\(r\) IN (\[[^\]]+\])/, count)
      assert freshness =~ in_list
      assert freshness =~ "max(coalesce(r.last_observed_at, r.observed_at))"
      assert freshness =~ "r.ingestor = 'mapper_topology_v1'"
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
