defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.HealthConditions
  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker

  defp unique_condition(tag) do
    condition = {:cleanup_worker_test, tag, System.unique_integer([:positive])}
    on_exit(fn -> HealthConditions.clear(condition) end)
    condition
  end

  defp attach_telemetry(event) do
    handler_id = "cleanup-worker-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn ev, measurements, metadata, pid ->
          send(pid, {:telemetry, ev, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "recovery_needed?/2 is true only when canonical count is below threshold and mapper evidence is present" do
    assert TopologyStateCleanupWorker.recovery_needed?(
             %{after_prune_edges: 0, mapper_evidence_edges: 5},
             1
           )

    refute TopologyStateCleanupWorker.recovery_needed?(
             %{after_prune_edges: 2, mapper_evidence_edges: 5},
             1
           )

    refute TopologyStateCleanupWorker.recovery_needed?(
             %{after_prune_edges: 0, mapper_evidence_edges: 0},
             1
           )
  end

  test "emit_cleanup_rebuild_telemetry/4 publishes before/after edge counters" do
    handler_id = "cleanup-rebuild-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :topology, :cleanup_rebuild, :completed],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stats = %{
      before_edges: 10,
      mapper_evidence_edges: 25,
      after_upsert_edges: 20,
      after_prune_edges: 18,
      stale_cutoff: "2026-02-26T00:00:00Z"
    }

    assert :ok = TopologyStateCleanupWorker.emit_cleanup_rebuild_telemetry(:completed, stats, 1)

    assert_receive {:telemetry, [:serviceradar, :topology, :cleanup_rebuild, :completed],
                    measurements, metadata}

    assert measurements.before_edges == 10
    assert measurements.after_upsert_edges == 20
    assert measurements.after_prune_edges == 18
    assert measurements.mapper_evidence_edges == 25
    assert measurements.min_canonical_edges == 1
    assert metadata.status == :completed
  end

  test "emit_recovery_telemetry/4 includes failure reason metadata" do
    handler_id = "cleanup-recovery-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:serviceradar, :topology, :cleanup_recovery, :failed],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stats = %{
      mapper_evidence_edges: 11,
      after_prune_edges: 0,
      stale_cutoff: "2026-02-26T00:00:00Z"
    }

    assert :ok =
             TopologyStateCleanupWorker.emit_recovery_telemetry(
               :failed,
               stats,
               1,
               :timeout
             )

    assert_receive {:telemetry, [:serviceradar, :topology, :cleanup_recovery, :failed],
                    measurements, metadata}

    assert measurements.mapper_evidence_edges == 11
    assert measurements.after_prune_edges == 0
    assert measurements.min_canonical_edges == 1
    assert metadata.status == :failed
    assert metadata.reason == ":timeout"
  end

  describe "recovery_outcome_stats/2 (fj #4378)" do
    test "uses the retry stats when the retry actually ran" do
      stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}
      retry_stats = %{after_prune_edges: 7, mapper_evidence_edges: 675}

      assert TopologyStateCleanupWorker.recovery_outcome_stats(stats, retry_stats) == retry_stats
    end

    test "falls back to the pre-retry stats when the retry was skipped (no edge counts)" do
      # The rebuild's change-detection guard skips an unchanged retry — nothing
      # changed, so the failing pre-retry counts still describe reality.
      stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}
      skipped = %{skipped: true, reason: :unchanged_topology}

      assert TopologyStateCleanupWorker.recovery_outcome_stats(stats, skipped) == stats
    end
  end

  describe "report_recovery_outcome/4 (honest recovery, fj #4378)" do
    test "(d) a retry that still has zero canonical edges with evidence emits failed, not completed" do
      attach_telemetry([:serviceradar, :topology, :cleanup_recovery, :failed])
      condition = unique_condition(:recovery_failed)

      stats = %{
        after_prune_edges: 0,
        mapper_evidence_edges: 675,
        stale_cutoff: "2026-07-02T07:51:15Z"
      }

      retry_stats = %{
        after_prune_edges: 0,
        mapper_evidence_edges: 675,
        stale_cutoff: "2026-07-02T07:51:15Z"
      }

      assert :failed =
               TopologyStateCleanupWorker.report_recovery_outcome(
                 stats,
                 retry_stats,
                 1,
                 condition: condition
               )

      assert_receive {:telemetry, [:serviceradar, :topology, :cleanup_recovery, :failed],
                      measurements, metadata}

      assert measurements.after_prune_edges == 0
      assert measurements.mapper_evidence_edges == 675
      assert metadata.status == :failed
      assert metadata.reason == ":canonical_edges_below_threshold"
      assert HealthConditions.unhealthy?(condition)
    end

    test "a skipped retry cannot claim completion while the original rebuild was failing" do
      attach_telemetry([:serviceradar, :topology, :cleanup_recovery, :failed])
      condition = unique_condition(:recovery_skipped)

      stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}
      skipped_retry = %{skipped: true, reason: :unchanged_topology}

      assert :failed =
               TopologyStateCleanupWorker.report_recovery_outcome(
                 stats,
                 skipped_retry,
                 1,
                 condition: condition
               )

      assert_receive {:telemetry, [:serviceradar, :topology, :cleanup_recovery, :failed], _, _}
      assert HealthConditions.unhealthy?(condition)
    end

    test "repeated identical failures deduplicate into one ongoing condition" do
      condition = unique_condition(:recovery_dedup)
      stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}
      retry_stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}

      for _ <- 1..3 do
        assert :failed =
                 TopologyStateCleanupWorker.report_recovery_outcome(
                   stats,
                   retry_stats,
                   1,
                   condition: condition
                 )
      end

      assert %{occurrences: 3} = HealthConditions.get(condition)
    end

    test "(e) a retry that restores canonical edges completes and clears the condition" do
      attach_telemetry([:serviceradar, :topology, :cleanup_recovery, :completed])
      condition = unique_condition(:recovery_cleared)

      stats = %{after_prune_edges: 0, mapper_evidence_edges: 675}

      assert :failed =
               TopologyStateCleanupWorker.report_recovery_outcome(
                 stats,
                 %{after_prune_edges: 0, mapper_evidence_edges: 675},
                 1,
                 condition: condition
               )

      assert HealthConditions.unhealthy?(condition)

      retry_stats = %{after_prune_edges: 12, mapper_evidence_edges: 675}

      assert :completed =
               TopologyStateCleanupWorker.report_recovery_outcome(
                 stats,
                 retry_stats,
                 1,
                 condition: condition
               )

      assert_receive {:telemetry, [:serviceradar, :topology, :cleanup_recovery, :completed],
                      measurements, metadata}

      assert measurements.after_prune_edges == 12
      assert metadata.status == :completed
      refute HealthConditions.unhealthy?(condition)
    end
  end
end
