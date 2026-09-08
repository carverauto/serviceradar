defmodule ServiceRadar.SweepJobs.SweepMonitorWorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.SweepMonitorWorker

  @moduletag :db_free

  test "missed-sweep diagnostics preserve an empty all-agent assignment" do
    payload =
      SweepMonitorWorker.missed_sweep_payload(
        sweep_group([]),
        ~U[2026-08-30 10:22:30Z],
        ~U[2026-08-30 10:20:00Z]
      )

    assert payload["agent_ids"] == []
    refute Map.has_key?(payload, "agent_id")
  end

  test "missed-sweep diagnostics preserve a one-agent selection" do
    payload =
      SweepMonitorWorker.missed_sweep_payload(
        sweep_group(["agent-a"]),
        ~U[2026-08-30 10:22:30Z],
        ~U[2026-08-30 10:20:00Z]
      )

    assert payload["agent_ids"] == ["agent-a"]
    refute Map.has_key?(payload, "agent_id")
  end

  test "missed-sweep diagnostics preserve every selected agent and explain aggregate recency" do
    payload =
      SweepMonitorWorker.missed_sweep_payload(
        sweep_group(["agent-a", "agent-b"]),
        ~U[2026-08-30 10:22:30Z],
        ~U[2026-08-30 10:20:00Z]
      )

    assert payload["agent_ids"] == ["agent-a", "agent-b"]
    refute Map.has_key?(payload, "agent_id")
    assert payload["last_run_at"] == "2026-08-30T10:00:00Z"
    assert payload["expected_by"] == "2026-08-30T10:20:00Z"
    assert payload["overdue_seconds"] == 150

    assert payload["details"]["last_run_at_meaning"] ==
             "last_run_at is the latest report received from any eligible agent " <>
               "in All mode or any selected agent in Selected mode. It is not proof " <>
               "that every member reported; use per-agent execution history to " <>
               "inspect coverage."
  end

  defp sweep_group(agent_ids) do
    %{
      id: "sweep-group-1",
      name: "Datacenter sweep",
      partition: "devices-central",
      agent_ids: agent_ids,
      interval: "15m",
      last_run_at: ~U[2026-08-30 10:00:00Z],
      schedule_type: :interval,
      cron_expression: nil
    }
  end
end
