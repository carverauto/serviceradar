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
end
