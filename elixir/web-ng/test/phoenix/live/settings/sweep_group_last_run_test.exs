defmodule ServiceRadarWebNGWeb.Settings.NetworksLive.SweepGroupLastRunTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Settings.NetworksLive.ActiveScansComponents

  test "prefers persisted last_run_at" do
    last_run_at = ~U[2026-08-12 20:16:07Z]

    group = %{
      last_run_at: last_run_at,
      executions: [%{started_at: ~U[2026-08-01 00:00:00Z], status: :completed}]
    }

    assert ActiveScansComponents.group_last_run_at(group) == last_run_at
  end

  test "falls back to latest execution when last_run_at is nil" do
    completed_at = ~U[2026-08-12 20:16:07Z]

    group = %{
      last_run_at: nil,
      executions: [%{completed_at: completed_at, started_at: ~U[2026-08-12 20:15:00Z], status: :completed}]
    }

    assert ActiveScansComponents.group_last_run_at(group) == completed_at
    assert %{state: :success} = ActiveScansComponents.persisted_sweep_command_status(group)
  end

  test "returns nil and no status when the group has never executed" do
    group = %{last_run_at: nil, executions: []}

    assert ActiveScansComponents.group_last_run_at(group) == nil
    assert ActiveScansComponents.persisted_sweep_command_status(group) == nil
  end
end
