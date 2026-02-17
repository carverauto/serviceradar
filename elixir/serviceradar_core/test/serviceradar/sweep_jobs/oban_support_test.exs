defmodule ServiceRadar.SweepJobs.ObanSupportTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyStateCleanupWorker
  alias ServiceRadar.SweepJobs.{ObanSupport, SweepDataCleanupWorker, SweepMonitorWorker}
  alias ServiceRadar.SweepJobs.SweepScheduleReconciler

  test "reports Oban unavailable when no instance is running" do
    refute ObanSupport.available?()
  end

  test "sweep scheduling returns oban_unavailable when Oban is missing" do
    assert {:error, :oban_unavailable} = SweepMonitorWorker.ensure_scheduled()
    assert {:error, :oban_unavailable} = SweepDataCleanupWorker.ensure_scheduled()
    assert {:error, :oban_unavailable} = TopologyStateCleanupWorker.ensure_scheduled()
  end

  test "reconciler skips work when Oban is unavailable" do
    pid = Process.whereis(SweepScheduleReconciler) || start_supervised!(SweepScheduleReconciler)
    send(pid, :reconcile)

    state = :sys.get_state(pid)
    assert is_map(state)
  end
end
