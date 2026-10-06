defmodule ServiceRadarWebNGWeb.MetricsRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarWebNGWeb.MetricsRouter

  @moduletag :db_free

  test "GET /metrics on internal listener succeeds without requiring auth" do
    reporter = ServiceRadarWebNGWeb.Telemetry.prometheus_reporter()

    if !Process.whereis(reporter) do
      start_supervised!({TelemetryMetricsPrometheus.Core, metrics: [], name: reporter, start_async: false})
    end

    conn =
      :get
      |> conn("/metrics")
      |> MetricsRouter.call(MetricsRouter.init([]))

    assert conn.status == 200
    assert conn |> get_resp_header("content-type") |> List.first() =~ "version=0.0.4"
    assert is_binary(conn.resp_body)
  end

  test "GET /health returns 200 ok" do
    conn =
      :get
      |> conn("/health")
      |> MetricsRouter.call(MetricsRouter.init([]))

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "unrecognized routes return 404" do
    conn =
      :get
      |> conn("/unknown")
      |> MetricsRouter.call(MetricsRouter.init([]))

    assert conn.status == 404
    assert conn.resp_body == "not found"
  end
end
