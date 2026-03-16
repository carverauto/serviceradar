defmodule ServiceRadarWebNGWeb.MetricsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "GET /metrics returns prometheus scrape output", %{conn: conn} do
    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> List.first() =~ "version=0.0.4"
    assert conn.resp_body =~ "serviceradar_tenant_usage_managed_devices_count"
  end
end
