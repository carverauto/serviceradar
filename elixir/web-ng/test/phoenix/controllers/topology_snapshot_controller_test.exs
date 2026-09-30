defmodule ServiceRadarWebNGWeb.TopologySnapshotControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  @moduletag :web_ng_shared_fixture_db

  alias ServiceRadarWebNG.Accounts.Scope

  setup :register_and_log_in_user

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    previous_gate_env = System.get_env("SERVICERADAR_MIGRATIONS_GATE")
    System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)

      if is_nil(previous_gate_env) do
        System.delete_env("SERVICERADAR_MIGRATIONS_GATE")
      else
        System.put_env("SERVICERADAR_MIGRATIONS_GATE", previous_gate_env)
      end
    end)

    :ok
  end

  test "show requires an explicit bounded detail selection", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    conn = get(conn, ~p"/topology/snapshot/latest")

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_detail"}
  end

  test "show rejects a global graph request", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    conn = get(conn, ~p"/topology/snapshot/latest", %{"kind" => "global"})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body) == %{"error" => "invalid_detail"}
  end

  test "show fails closed without an authenticated scope", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    conn = ServiceRadarWebNGWeb.TopologySnapshotController.show(conn, %{})

    assert conn.halted
    assert conn.status == 401
    assert Jason.decode!(conn.resp_body) == %{"error" => "unauthorized"}
  end

  test "show returns forbidden without topology snapshot permission", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)

    conn =
      conn
      |> assign(:current_scope, %Scope{user: %{id: "viewer", email: "viewer@example.com"}, permissions: MapSet.new()})
      |> ServiceRadarWebNGWeb.TopologySnapshotController.show(%{})

    assert conn.halted
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body) == %{"error" => "forbidden"}
  end

  test "show returns unavailable when god view is disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)

    conn = get(conn, ~p"/topology/snapshot/latest")

    assert conn.status == 404
    assert Jason.decode!(conn.resp_body) == %{"error" => "god_view_disabled"}
  end
end
