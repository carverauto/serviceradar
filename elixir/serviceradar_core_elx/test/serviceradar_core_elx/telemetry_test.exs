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

  test "prometheus reporter can register the shared metric set" do
    name = :"prometheus_metrics_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             TelemetryMetricsPrometheus.Core.start_link(
               metrics: ServiceRadarCoreElx.Telemetry.metrics(),
               name: name,
               start_async: false
             )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end
end
