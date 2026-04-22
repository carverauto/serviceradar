defmodule ServiceRadarCoreElx.TelemetryTest do
  use ExUnit.Case, async: true

  test "uses a stable prometheus reporter name" do
    assert ServiceRadarCoreElx.Telemetry.prometheus_reporter() ==
             :serviceradar_core_elx_prometheus_metrics
  end

  test "exports the shared ServiceRadar telemetry metrics" do
    assert ServiceRadarCoreElx.Telemetry.metrics() == ServiceRadar.Telemetry.metrics()
  end
end
