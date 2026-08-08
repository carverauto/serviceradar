defmodule ServiceRadarWebNGWeb.MetricsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  test "GET /metrics returns prometheus scrape output", %{conn: conn} do
    ServiceRadarWebNGWeb.Telemetry.measure_tenant_usage()

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> List.first() =~ "version=0.0.4"
    assert conn.resp_body =~ "serviceradar_tenant_usage_managed_devices_count"
    assert conn.resp_body =~ "serviceradar_managed_devices"
    assert conn.resp_body =~ "serviceradar_collectors_total"
    assert conn.resp_body =~ "serviceradar_leaf_nodes_total"
  end

  test "GET /metrics exposes always-on storage gauges after a storage measurement", %{conn: conn} do
    ServiceRadarWebNGWeb.Telemetry.measure_storage_usage()

    conn = get(conn, ~p"/metrics")

    assert conn.status == 200
    assert conn.resp_body =~ "serviceradar_storage_database_bytes"
    assert conn.resp_body =~ "serviceradar_storage_nontelemetry_bytes"

    for table <- ServiceRadar.ColdTier.Registry.table_names() do
      assert conn.resp_body =~ ~s(serviceradar_storage_hot_bytes{table="#{table}"})
    end
  end
end
