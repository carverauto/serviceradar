defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.TelemetryMetricsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics

  @cutoff ~U[2026-09-15 12:00:00Z]

  test "postgres latest-row SQL is DISTINCT ON-free and has no hive prune" do
    {sql, params} =
      Metrics.latest_metric_query(
        ["sr:device-1"],
        ["192.0.2.10"],
        [1],
        ["ifHCInOctets"],
        @cutoff
      )

    refute sql =~ "DISTINCT ON"
    refute sql =~ "_partition_date"
    assert sql =~ "ROW_NUMBER()"
    assert sql =~ "platform.timeseries_metrics"
    assert params == [["sr:device-1"], ["192.0.2.10"], [1], ["ifHCInOctets"], @cutoff]
  end

  test "duckdb latest-row SQL prunes hive partitions and still avoids DISTINCT ON" do
    cfg =
      AnalyticsStore.Config.validate!(
        AnalyticsStore.Config.load(
          driver: :pg_duckdb,
          storage: :filesystem,
          filesystem_path: "/var/lib/serviceradar/analytics",
          head_host: "analytics-head",
          tables: "timeseries_metrics"
        )
      )

    {sql, params} =
      Metrics.latest_metric_query(
        ["sr:device-1"],
        ["192.0.2.10"],
        [1],
        ["ifHCInOctets"],
        @cutoff,
        config: cfg
      )

    refute sql =~ "DISTINCT ON"
    assert sql =~ "m._partition_date >= $6::date"
    assert sql =~ "ROW_NUMBER()"

    assert params == [
             ["sr:device-1"],
             ["192.0.2.10"],
             [1],
             ["ifHCInOctets"],
             @cutoff,
             ~D[2026-09-15]
           ]
  end

  test "hybrid recent telemetry SQL has no archive-only column" do
    cfg = AnalyticsStore.Config.load(driver: :hybrid, tables: "timeseries_metrics")

    {sql, params} =
      Metrics.latest_metric_query(
        ["sr:synthetic-device"],
        ["192.0.2.23"],
        [2],
        ["ifHCInOctets"],
        @cutoff,
        config: cfg,
        now: ~U[2026-09-16 12:00:00Z]
      )

    refute sql =~ "_partition_date"
    assert length(params) == 5
  end
end
