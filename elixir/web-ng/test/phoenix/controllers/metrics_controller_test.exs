defmodule ServiceRadarWebNGWeb.MetricsControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  @test_metrics_token "test-web-ng-metrics-bearer-token-12345"

  setup do
    previous_token = Application.get_env(:serviceradar_web_ng, :metrics_token)
    Application.put_env(:serviceradar_web_ng, :metrics_token, @test_metrics_token)

    on_exit(fn ->
      if previous_token do
        Application.put_env(:serviceradar_web_ng, :metrics_token, previous_token)
      else
        Application.delete_env(:serviceradar_web_ng, :metrics_token)
      end
    end)

    :ok
  end

  test "unauthenticated GET /metrics on public listener is refused with 401", %{conn: conn} do
    conn = get(conn, ~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
  end

  test "GET /metrics with invalid bearer token is refused with 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer invalid-token")
      |> get(~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "GET /metrics accepts the configured token when it has surrounding whitespace", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :metrics_token, "\n" <> @test_metrics_token <> "\n")

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @test_metrics_token)
      |> get(~p"/metrics")

    assert conn.status == 200
  end

  test "GET /metrics with missing token when no token configured is refused", %{conn: conn} do
    Application.delete_env(:serviceradar_web_ng, :metrics_token)

    conn = get(conn, ~p"/metrics")

    assert conn.status == 401
    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end

  test "authorized GET /metrics returns prometheus scrape output", %{conn: conn} do
    ServiceRadarWebNGWeb.Telemetry.measure_tenant_usage()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @test_metrics_token)
      |> get(~p"/metrics")

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> List.first() =~ "version=0.0.4"
    assert conn.resp_body =~ "serviceradar_tenant_usage_managed_devices_count"
    assert conn.resp_body =~ "serviceradar_managed_devices"
    assert conn.resp_body =~ "serviceradar_collectors_total"
    assert conn.resp_body =~ "serviceradar_leaf_nodes_total"
  end

  test "authorized GET /metrics exposes always-on storage gauges after a storage measurement", %{conn: conn} do
    ServiceRadarWebNGWeb.Telemetry.measure_storage_usage()

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> @test_metrics_token)
      |> get(~p"/metrics")

    assert conn.status == 200
    assert conn.resp_body =~ "serviceradar_storage_database_bytes"
    assert conn.resp_body =~ "serviceradar_storage_nontelemetry_bytes"

    for table <- ServiceRadar.ColdTier.Registry.table_names() do
      assert conn.resp_body =~ ~s(serviceradar_storage_hot_bytes{table="#{table}"})
    end
  end
end
