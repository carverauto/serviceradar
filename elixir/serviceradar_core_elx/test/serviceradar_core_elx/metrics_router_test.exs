defmodule ServiceRadarCoreElx.MetricsRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ServiceRadarCoreElx.MetricsRouter

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "serves prometheus metrics" do
    # The suite boots this supervisor in test_helper.exs. Starting it again
    # raises :already_started, and the scrape target is the same reporter.
    if is_nil(Process.whereis(ServiceRadarCoreElx.Telemetry)) do
      start_supervised!(ServiceRadarCoreElx.Telemetry)
    end

    conn =
      :get
      |> conn("/metrics")
      |> MetricsRouter.call([])

    assert conn.status == 200
    assert ["text/plain; version=0.0.4; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert byte_size(conn.resp_body) > 0
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
