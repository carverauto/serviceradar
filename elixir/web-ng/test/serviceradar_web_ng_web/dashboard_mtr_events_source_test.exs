defmodule ServiceRadarWebNGWeb.DashboardMtrEventsSourceTest do
  use ExUnit.Case, async: true

  @moduletag :db_free

  @traffic Path.expand(
             "../../lib/serviceradar_web_ng_web/live/dashboard_live/data/traffic_sparklines.ex",
             __DIR__
           )
  @service Path.expand(
             "../../lib/serviceradar_web_ng_web/live/dashboard_live/data/service_sparklines.ex",
             __DIR__
           )
  @mtr Path.expand("../../lib/serviceradar_web_ng_web/live/dashboard_live/data/mtr.ex", __DIR__)
  @load Path.expand("../../lib/serviceradar_web_ng_web/live/dashboard_live/data/load.ex", __DIR__)

  @external_resource @traffic
  @external_resource @service
  @external_resource @mtr
  @external_resource @load

  test "MTR latency cards read Timescale hops instead of OTEL traces_stats_5m" do
    traffic = File.read!(@traffic)
    service = File.read!(@service)
    mtr = File.read!(@mtr)
    load = File.read!(@load)

    assert traffic =~ "mtr_timeseries_sparkline(time_window, :latency_ms)"
    assert traffic =~ "mtr_timeseries_sparkline(time_window, :loss_pct)"
    refute traffic =~ "trace_sparkline(time_window, :latency_ms"
    assert service =~ "FROM mtr_traces"
    assert service =~ "INNER JOIN mtr_hops"
    assert mtr =~ "mtr_timeseries_summary"
    assert mtr =~ "FROM mtr_traces"
    assert load =~ "merge_mtr_summaries(mtr_timeseries"
  end
end
