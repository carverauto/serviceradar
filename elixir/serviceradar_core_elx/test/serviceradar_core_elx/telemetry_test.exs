defmodule ServiceRadarCoreElx.TelemetryTest do
  use ExUnit.Case, async: true

  test "uses a stable prometheus reporter name" do
    assert ServiceRadarCoreElx.Telemetry.prometheus_reporter() ==
             :serviceradar_core_elx_prometheus_metrics
  end

  test "exports the shared ServiceRadar telemetry metrics" do
    assert ServiceRadarCoreElx.Telemetry.metrics() == ServiceRadar.Telemetry.metrics()
  end

  test "exports prefix-tag health metrics" do
    metric_names = Enum.map(ServiceRadarCoreElx.Telemetry.metrics(), & &1.name)

    assert [:serviceradar, :prefix_tags, :lookup, :count] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_age, :age_seconds] in metric_names
    assert [:serviceradar, :prefix_tags, :snapshot_freshness, :known] in metric_names
    assert [:serviceradar, :prefix_tags, :import, :record_count] in metric_names
  end
end
