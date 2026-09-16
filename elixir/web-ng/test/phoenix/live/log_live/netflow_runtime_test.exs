defmodule ServiceRadarWebNGWeb.LogLive.NetflowRuntimeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowRuntime

  @moduletag :db_free

  test "inactive tabs do not load NetFlow panels" do
    assert {:skipped, :inactive_panel} =
             NetflowRuntime.load_summary("logs", fn -> flunk("loaded inactive summary") end)

    assert {:skipped, :inactive_panel} =
             NetflowRuntime.load_activity("logs", "explorer", fn -> flunk("loaded inactive activity") end)
  end

  test "overview view skips explorer activity loaders" do
    assert {:skipped, :inactive_panel} =
             NetflowRuntime.load_activity("netflows", "overview", fn -> flunk("loaded overview activity") end)

    refute NetflowRuntime.should_load_activity?("netflows", "overview")
    assert NetflowRuntime.should_load_activity?("netflows", "explorer")
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
             NetflowRuntime.load_activity("netflows", "all", fn -> {:ok, scope} end)
  end
end
