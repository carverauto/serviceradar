defmodule ServiceRadar.AnalyticsStore.TimeseriesQueriesTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore
  alias ServiceRadar.AnalyticsStore.TimeseriesQueries

  @cutoff ~U[2026-09-15 12:00:00Z]

  test "sparkline SQL uses epoch flooring instead of time_bucket" do
    {sql, params} =
      TimeseriesQueries.interface_sparkline_sql(
        @cutoff,
        ["sr:device-1"],
        [1],
        ["ifHCInOctets"],
        900
      )

    refute sql =~ "time_bucket"
    refute sql =~ "_partition_date"
    assert sql =~ "extract(epoch FROM m.timestamp)"
    # Both engines zip SELECT-list unnests, including NULL padding. DuckDB
    # rejects the PostgreSQL-only multi-argument FROM unnest(text[], int[]).
    assert sql =~ "SELECT unnest($2::text[]) AS device_id, unnest($3::int[]) AS if_index"
    assert params == [@cutoff, ["sr:device-1"], [1], ["ifHCInOctets"], 900]
  end

  test "duckdb sparkline SQL adds a hive prune" do
    {sql, _params} =
      TimeseriesQueries.interface_sparkline_sql(
        @cutoff,
        ["sr:device-1"],
        [1],
        ["ifHCInOctets"],
        900,
        config: duckdb_cfg()
      )

    refute sql =~ "time_bucket"
    assert sql =~ "m._partition_date >= DATE '2026-09-15'"
  end

  test "latest-value SQL is LIMIT 1, not DISTINCT ON" do
    {sql, params} =
      TimeseriesQueries.latest_interface_value_sql(
        "sr:device-1",
        "ifHCInOctets",
        1,
        @cutoff
      )

    refute sql =~ "DISTINCT ON"
    assert sql =~ "ORDER BY m.timestamp DESC"
    assert sql =~ "LIMIT 1"
    assert params == ["sr:device-1", "ifHCInOctets", 1, @cutoff]
  end

  test "hybrid SQL builders agree with execution about recent versus historical windows" do
    cfg = AnalyticsStore.Config.load(driver: :hybrid, tables: "timeseries_metrics")
    opts = [config: cfg, now: ~U[2026-09-16 12:00:00Z]]
    {recent, _} = TimeseriesQueries.snmp_present_sql("sr:synthetic-device", @cutoff, opts)
    refute recent =~ "_partition_date"

    {historical, _} =
      TimeseriesQueries.snmp_present_sql(
        "sr:synthetic-device",
        DateTime.add(@cutoff, -31, :day),
        opts
      )

    assert historical =~ "_partition_date"
  end

  defp duckdb_cfg do
    AnalyticsStore.Config.validate!(
      AnalyticsStore.Config.load(
        driver: :pg_duckdb,
        storage: :filesystem,
        filesystem_path: "/var/lib/serviceradar/analytics",
        head_host: "analytics-head",
        tables: "timeseries_metrics"
      )
    )
  end
end
