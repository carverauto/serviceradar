defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowRuntime

  @moduletag :db_free

  test "inactive tabs do not load NetFlow panels" do
    assert {:skipped, :inactive_panel} =
             NetflowRuntime.load_summary("logs", fn -> flunk("loaded inactive summary") end)

    assert {:skipped, :inactive_panel} =
             NetflowRuntime.load_panel("logs", "traffic", :stacked_timeseries, fn ->
               flunk("loaded inactive panel")
             end)
  end

  test "a panel loads on every view that renders it" do
    for view <- ["overview", "traffic", "all"] do
      assert NetflowRuntime.should_load_panel?("netflows", view, :stacked_timeseries)
      assert {:ok, :loaded} = NetflowRuntime.load_panel("netflows", view, :stacked_timeseries, fn -> :loaded end)
    end

    # The talkers icicle is drawn from the Sankey edges, so both views need them.
    for view <- ["topology", "talkers", "all"] do
      assert NetflowRuntime.should_load_panel?("netflows", view, :sankey)
      assert {:ok, :loaded} = NetflowRuntime.load_panel("netflows", view, :sankey, fn -> :loaded end)
    end
  end

  test "a panel does not load on a view that does not render it" do
    for view <- ["topology", "talkers", "explorer"] do
      assert {:skipped, :inactive_panel} =
               NetflowRuntime.load_panel("netflows", view, :stacked_timeseries, fn ->
                 flunk("loaded stacked series on #{view}")
               end)
    end

    for view <- ["overview", "traffic", "explorer"] do
      assert {:skipped, :inactive_panel} =
               NetflowRuntime.load_panel("netflows", view, :sankey, fn ->
                 flunk("loaded sankey on #{view}")
               end)
    end
  end

  test "active loader errors remain errors" do
    assert {:error, :srql_timeout} =
             NetflowRuntime.load_summary("netflows", fn -> {:error, :srql_timeout} end)

    assert {:ok, %{total: 3}} =
             NetflowRuntime.load_summary("netflows", fn -> %{total: 3} end)
  end

  test "authenticated scope is forwarded to the active loader" do
    scope = %{actor_id: "actor-alpha"}

    assert {:ok, ^scope} =
             NetflowRuntime.load_panel("netflows", "all", :sankey, fn -> {:ok, scope} end)
  end

  describe "run_concurrently/2" do
    test "returns every loader's result under its key" do
      assert NetflowRuntime.run_concurrently([
               {:ports, fn -> [443, 53] end, []},
               {:summary, fn -> %{total: 3} end, %{}}
             ]) == %{ports: [443, 53], summary: %{total: 3}}

      assert NetflowRuntime.run_concurrently([]) == %{}
    end

    test "loaders overlap instead of queueing behind each other" do
      parent = self()

      # Every loader blocks until all of them have started. Run in sequence,
      # the first would wait forever for siblings that were never launched.
      jobs =
        for n <- 1..4 do
          {:"job_#{n}",
           fn ->
             send(parent, {:started, self()})

             receive do
               :release -> n
             after
               2_000 -> :never_released
             end
           end, :default}
        end

      task = Task.async(fn -> NetflowRuntime.run_concurrently(jobs) end)

      pids =
        for _ <- 1..4 do
          assert_receive {:started, pid}, 1_000
          pid
        end

      Enum.each(pids, &send(&1, :release))

      assert Task.await(task) == %{job_1: 1, job_2: 2, job_3: 3, job_4: 4}
    end

    test "a loader that outlives the timeout costs only its own panel" do
      assert NetflowRuntime.run_concurrently(
               [
                 {:stuck, fn -> Process.sleep(:infinity) end, :stuck_default},
                 {:fine, fn -> :loaded end, :fine_default}
               ],
               timeout: 50
             ) == %{stuck: :stuck_default, fine: :loaded}
    end
  end
end
