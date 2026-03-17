defmodule ServiceRadarWebNGWeb.HealthControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "GET /health/live returns ok", %{conn: conn} do
    conn = get(conn, ~p"/health/live")

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "GET /health/ready returns ready", %{conn: conn} do
    conn = get(conn, ~p"/health/ready")

    assert conn.status == 200
    assert conn.resp_body == "ready"
  end

  test "GET /health delegates to readiness", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    assert conn.resp_body == "ready"
  end
end
