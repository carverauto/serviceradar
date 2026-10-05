defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuildTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ServiceRadar.NetworkDiscovery.RuntimeTopologyProjection
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.CanonicalRebuild
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Queries.CanonicalRebuild, as: Queries

  @moduletag :db_free

  @heartbeat_ms 3_600_000

  # Synthetic timestamps straddle a cutoff by one second.
  @clock ~U[2001-02-03 00:00:00Z]
  @cutoff "2001-02-03T00:00:00Z"
  @expired "2001-02-02T23:59:59Z"
  @recent "2001-02-03T00:00:01Z"

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
    test "unchanged input across restart skips the rebuild" do
      stored = {"2:aa", DateTime.shift(@clock, second: -1)}

      assert {:skip, %{skipped: true, reason: :unchanged_topology}} =
               CanonicalRebuild.skip_decision("2:aa", stored, @heartbeat_ms, @clock)
    end

    test "changed input forces a rebuild even when its edge count is unchanged" do
      stored = {"2:aa", DateTime.shift(@clock, second: -1)}

      assert {:proceed, "2:bb"} =
               CanonicalRebuild.skip_decision("2:bb", stored, @heartbeat_ms, @clock)
    end

    test "an unavailable current fingerprint fails open" do
      stored = {"1:cc", @clock}

      assert {:proceed, nil} =
               CanonicalRebuild.skip_decision(nil, stored, @heartbeat_ms, @clock)
    end

    test "a missing stored fingerprint requires an initial rebuild" do
      assert {:proceed, "3:dd"} =
               CanonicalRebuild.skip_decision("3:dd", nil, @heartbeat_ms, @clock)
    end

    test "unchanged input past the heartbeat deadline requires a rebuild" do
      expired_at = DateTime.add(@clock, -@heartbeat_ms - 1, :millisecond)

      assert {:proceed, "4:ee"} =
               CanonicalRebuild.skip_decision(
                 "4:ee",
                 {"4:ee", expired_at},
                 @heartbeat_ms,
                 @clock
               )
    end

    test "a future stored timestamp does not force an unchanged rebuild" do
      future_at = DateTime.shift(@clock, second: 1)

      assert {:skip, %{skipped: true, reason: :unchanged_topology}} =
               CanonicalRebuild.skip_decision(
                 "5:ff",
                 {"5:ff", future_at},
                 @heartbeat_ms,
                 @clock
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
    test "writes a fingerprint and includes it in conflict updates" do
      assert {:ok, %{rows: 0}} =
               RuntimeTopologyProjection.refresh_from_graph(
                 graph: __MODULE__.EmptyGraph,
                 repo: __MODULE__.CapturingRepo,
                 input_hash: "0:00"
               )

      assert_receive {:insert_all, "runtime_topology_projection_meta", [attrs], opts}
      assert attrs.input_hash == "0:00"
      assert %DateTime{} = attrs.input_hashed_at

      assert {:replace, replace_fields} = Keyword.fetch!(opts, :on_conflict)
      assert :input_hash in replace_fields
      assert :input_hashed_at in replace_fields
    end

    test "omits fingerprint columns when no fingerprint is supplied" do
      assert {:ok, %{rows: 0}} =
               RuntimeTopologyProjection.refresh_from_graph(
                 graph: __MODULE__.EmptyGraph,
                 repo: __MODULE__.CapturingRepo
               )

      assert_receive {:insert_all, "runtime_topology_projection_meta", [attrs], opts}
      refute Map.has_key?(attrs, :input_hash)
      refute Map.has_key?(attrs, :input_hashed_at)

      assert {:replace, replace_fields} = Keyword.fetch!(opts, :on_conflict)
      refute :input_hash in replace_fields
    end
  end

  describe "starvation_check/5" do
    test "expired evidence prevents pruning even when canonical edges remain" do
      assert :starved = CanonicalRebuild.starvation_check(2, 7, @expired, @cutoff, 0)
    end

    test "an empty canonical graph with expired evidence is starved" do
      assert :starved = CanonicalRebuild.starvation_check(0, 3, @expired, @cutoff, 0)
    end

    test "an empty canonical graph with unknown evidence freshness is starved" do
      assert :starved = CanonicalRebuild.starvation_check(0, 1, nil, @cutoff, 0)
    end

    test "fresh evidence cannot excuse an empty canonical graph" do
      assert :starved = CanonicalRebuild.starvation_check(0, 4, @recent, @cutoff, 0)
    end

    test "fresh evidence and a nonempty canonical graph permit pruning" do
      assert :ok = CanonicalRebuild.starvation_check(3, 8, @recent, @cutoff, 0)
    end

    test "no evidence means there is no starvation condition" do
      assert :ok = CanonicalRebuild.starvation_check(0, 0, nil, @cutoff, 0)
    end

    test "unknown freshness permits a nonempty canonical graph" do
      assert :ok = CanonicalRebuild.starvation_check(4, 9, nil, @cutoff, 0)
    end

    test "the configurable floor includes its exact boundary" do
      for remaining <- [1, 2] do
        assert :starved =
                 CanonicalRebuild.starvation_check(remaining, 6, @recent, @cutoff, 2)
      end

      assert :ok = CanonicalRebuild.starvation_check(3, 6, @recent, @cutoff, 2)
    end
  end

  describe "prune_guard_check/4" do
    test "refuses deletion above the configured fraction, including the entire graph" do
      assert {:refuse, :mass_deletion} = CanonicalRebuild.prune_guard_check(3, 4, 0.5, false)
      assert {:refuse, :mass_deletion} = CanonicalRebuild.prune_guard_check(1, 1, 0.5, false)
    end

    test "allows pruning exactly at the configured fraction and below it" do
      assert :allow = CanonicalRebuild.prune_guard_check(2, 8, 0.25, false)
      assert :allow = CanonicalRebuild.prune_guard_check(1, 8, 0.25, false)
    end

    test "zero candidates permits both empty and nonempty graphs" do
      for total <- [0, 3] do
        assert :allow = CanonicalRebuild.prune_guard_check(0, total, 0.25, false)
      end
    end

    test "operator override permits deletion above the configured fraction" do
      assert :allow = CanonicalRebuild.prune_guard_check(5, 6, 0.25, true)
    end

    test "an unavailable candidate count refuses pruning" do
      assert {:refuse, :candidate_count_unavailable} =
               CanonicalRebuild.prune_guard_check(nil, 2, 0.25, false)
    end
  end

  describe "report_starvation/5" do
    test "emits independent counts and timestamps and records an unhealthy condition" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :starved])
      condition = unique_condition(:starved)
      counts = %{before_edges: 5, mapper_evidence_edges: 11, after_upsert_edges: 3}

      log =
        capture_log(fn ->
          assert :ok =
                   CanonicalRebuild.report_starvation(
                     counts,
                     @cutoff,
                     @expired,
                     0,
                     condition: condition
                   )
        end)

      assert log =~ "Canonical topology rebuild starved"

      assert_receive {:telemetry, [:serviceradar, :topology, :canonical_rebuild, :starved],
                      measurements, metadata}

      assert measurements.before_edges == 5
      assert measurements.mapper_evidence_edges == 11
      assert measurements.after_upsert_edges == 3
      assert metadata.stale_cutoff == @cutoff
      assert metadata.evidence_max_last_observed_at == @expired
      assert HealthConditions.unhealthy?(condition)
    end

    test "repeated starvation updates one ongoing condition" do
      condition = unique_condition(:starved_repeat)
      counts = %{before_edges: 4, mapper_evidence_edges: 6, after_upsert_edges: 0}

      capture_log(fn ->
        for _ <- 1..2 do
          assert :ok =
                   CanonicalRebuild.report_starvation(
                     counts,
                     @cutoff,
                     @recent,
                     0,
                     condition: condition
                   )
        end
      end)

      assert %{occurrences: 2} = HealthConditions.get(condition)
    end
  end

  describe "report_prune_refusal/5" do
    test "emits candidate counts and the configured fraction" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :prune_refused])
      counts = %{before_edges: 8, mapper_evidence_edges: 13, after_upsert_edges: 6}

      log =
        capture_log(fn ->
          assert :ok =
                   CanonicalRebuild.report_prune_refusal(
                     :mass_deletion,
                     3,
                     counts,
                     @cutoff,
                     0.25
                   )
        end)

      assert log =~ "Canonical topology stale prune refused"

      assert_receive {:telemetry, [:serviceradar, :topology, :canonical_rebuild, :prune_refused],
                      measurements, metadata}

      assert measurements.prune_candidates == 3
      assert measurements.before_edges == 8
      assert metadata.reason == :mass_deletion
      assert metadata.max_fraction == 0.25
      assert metadata.stale_cutoff == @cutoff
    end
  end

  describe "finalize_self_heal_outcome/5" do
    test "an empty result with evidence records failure and an unhealthy condition" do
      attach_telemetry([:serviceradar, :topology, :canonical_rebuild, :self_heal_failed])
      condition = unique_condition(:self_heal_failed)

      log =
        capture_log(fn ->
          result =
            CanonicalRebuild.finalize_self_heal_outcome(2, 0, 5, 1, condition: condition)

          assert result.status == :failed
          assert result.reason == :canonical_edges_below_threshold
          assert result.after == 0
        end)

      assert log =~ "Canonical topology self-heal FAILED"

      assert_receive {:telemetry,
                      [:serviceradar, :topology, :canonical_rebuild, :self_heal_failed],
                      measurements, metadata}

      assert measurements.after_edges == 0
      assert measurements.mapper_evidence_edges == 5
      assert metadata.reason == :canonical_edges_below_threshold
      assert HealthConditions.unhealthy?(condition)
    end

    test "repeated below-threshold results update one ongoing condition" do
      condition = unique_condition(:self_heal_dedup)

      capture_log(fn ->
        for _ <- 1..2 do
          assert %{status: :failed} =
                   CanonicalRebuild.finalize_self_heal_outcome(3, 1, 7, 2, condition: condition)
        end
      end)

      assert %{occurrences: 2} = HealthConditions.get(condition)
    end

    test "recovery above the threshold completes and clears the condition" do
      condition = unique_condition(:self_heal_recovery)

      capture_log(fn ->
        assert %{status: :failed} =
                 CanonicalRebuild.finalize_self_heal_outcome(2, 1, 8, 2, condition: condition)
      end)

      assert HealthConditions.unhealthy?(condition)

      recovery_log =
        capture_log([level: :info], fn ->
          result =
            CanonicalRebuild.finalize_self_heal_outcome(1, 3, 8, 2, condition: condition)

          assert result.status == :completed
          assert result.after == 3
        end)

      assert recovery_log =~ "Canonical topology self-heal recovered canonical edges"
      refute HealthConditions.unhealthy?(condition)
    end
  end

  describe "prune guard queries" do
    test "prune candidate count query mirrors the prune WHERE clause exactly" do
      prune = Queries.canonical_rebuild_prune_query(@cutoff)
      count = Queries.canonical_rebuild_prune_candidate_count_query(@cutoff)

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
