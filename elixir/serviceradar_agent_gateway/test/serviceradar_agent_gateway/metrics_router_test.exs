defmodule ServiceRadarAgentGateway.MetricsRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarAgentGateway.MetricsRouter

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "serves prometheus metrics" do
    start_supervised!(ServiceRadarAgentGateway.Telemetry)

    conn =
      :get
      |> conn("/metrics")
      |> MetricsRouter.call([])

    assert conn.status == 200
    assert ["text/plain; version=0.0.4; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert is_binary(conn.resp_body)
  end

  test "serves health check" do
    conn =
      :get
      |> conn("/health")
      |> MetricsRouter.call([])

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end

  test "returns 404 for unknown routes" do
    conn =
      :get
      |> conn("/unknown")
      |> MetricsRouter.call([])

    assert conn.status == 404
  end
end
