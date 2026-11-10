defmodule ServiceRadar.SweepJobs.LeaseRefreshTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.SweepJobs.LeaseRefresh

  setup do
    {supervisor, opts} = LeaseRefresh.task_supervisor_child()

    if !Process.whereis(Keyword.fetch!(opts, :name)) do
      start_supervised!({supervisor, opts})
    end

    :ok
  end

  test "the result reaches the session with its attempt, however long the refresh ran" do
    test_pid = self()

    refresh = fn ->
      send(test_pid, {:refreshing, self()})

      receive do
        {:finish, result} -> result
      end
    end

    assert {:ok, runner} = LeaseRefresh.start("agent-01", self(), 3, refresh)
    monitor = Process.monitor(runner)
    assert_receive {:refreshing, work}

    # Starting returned while the work is still going; nothing is reported until it ends.
    refute_receive {:sweep_lease_refresh_result, _attempt, _result}, 100

    send(work, {:finish, {:error, {:lease_refresh_incomplete, 1}}})

    assert_receive {:sweep_lease_refresh_result, 3, {:error, {:lease_refresh_incomplete, 1}}}
    assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}
  end

  test "a refresh whose session ended is stopped and reports nothing" do
    test_pid = self()
    session = spawn(fn -> Process.sleep(:infinity) end)

    refresh = fn ->
      send(test_pid, {:refreshing, self()})
      Process.sleep(:infinity)
    end

    assert {:ok, runner} = LeaseRefresh.start("agent-01", session, 0, refresh)
    assert_receive {:refreshing, work}
    work_monitor = Process.monitor(work)
    runner_monitor = Process.monitor(runner)

    Process.exit(session, :kill)

    assert_receive {:DOWN, ^work_monitor, :process, ^work, :killed}
    assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}
  end

  test "a refresh that crashes ends without a result, which its monitor sees" do
    assert {:ok, runner} = LeaseRefresh.start("agent-01", self(), 0, fn -> exit(:boom) end)
    monitor = Process.monitor(runner)

    assert_receive {:DOWN, ^monitor, :process, ^runner, reason}
    assert reason != :normal
    refute_receive {:sweep_lease_refresh_result, _attempt, _result}, 50
  end
end
