defmodule ServiceRadarWebNG.SRQLAnalyticsRepoTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.SRQL

  @web_root Path.expand("../../lib", __DIR__)

  test "postgres translations keep the primary repo" do
    assert SRQL.srql_repo(%{"sql" => "select 1"}) == Repo
  end

  test "duckdb translations fail closed when the analytics head is down" do
    assert SRQL.srql_repo(%{"sql" => "select 1", "dialect" => "duckdb"}) ==
             {:error, :analytics_head_unavailable}
  end

  test "direct timeseries_metrics readers go through the analytics-store picker" do
    topology =
      File.read!(
        Path.join(@web_root, "serviceradar_web_ng_web/live/dashboard_live/data/topology.ex")
      )

    god_view = File.read!(Path.join(@web_root, "serviceradar_web_ng/topology/god_view_stream.ex"))

    interfaces =
      File.read!(
        Path.join(@web_root, "serviceradar_web_ng_web/live/device_live/interface_data.ex")
      )

    assert topology =~ "AnalyticsStore.SQL.query"
    assert topology =~ "TimeseriesQueries.interface_sparkline_sql"
    refute topology =~ "time_bucket("
    refute topology =~ ~s[relation_exists?("platform.timeseries_metrics")]

    assert god_view =~ "AnalyticsStore.SQL.query"
    assert god_view =~ "TimeseriesQueries.interface_sparkline_sql"
    refute god_view =~ "time_bucket("
    refute god_view =~ ~s[relation_exists?("platform.timeseries_metrics")]

    assert interfaces =~ "AnalyticsStore.SQL.query"
    assert interfaces =~ "TimeseriesQueries.snmp_present_sql"
    refute interfaces =~ ~s[FROM platform.timeseries_metrics]
  end
end
