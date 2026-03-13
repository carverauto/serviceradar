defmodule ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker

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
end
