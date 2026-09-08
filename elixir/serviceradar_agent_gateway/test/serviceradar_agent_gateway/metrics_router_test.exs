defmodule ServiceRadarAgentGateway.MetricsRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarAgentGateway.MetricsRouter

  @moduletag :requires_app

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "serves prometheus metrics" do
    assert Process.alive?(telemetry_pid())

    :telemetry.execute(
      [:serviceradar, :agent_gateway, :push, :complete],
      %{service_count: 1},
      %{gateway_id: "test-gateway", domain: "test-domain"}
    )

    conn =
      :get
      |> conn("/metrics")
      |> MetricsRouter.call([])

    assert conn.status == 200
    assert ["text/plain; version=0.0.4; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert String.contains?(conn.resp_body, "serviceradar_agent_gateway_push_complete_count")
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

  defp telemetry_pid do
    Process.whereis(ServiceRadarAgentGateway.Telemetry) ||
      start_supervised!(ServiceRadarAgentGateway.Telemetry)
  end
end
