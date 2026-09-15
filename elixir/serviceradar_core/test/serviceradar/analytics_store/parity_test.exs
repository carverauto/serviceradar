defmodule ServiceRadar.AnalyticsStore.ParityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Parity
  alias ServiceRadar.ColdTier.Registry

  test "postgres stats SQL is a closed window against the hypertable" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    start_at = ~U[2026-09-14 12:00:00Z]
    stop_at = ~U[2026-09-14 18:00:00Z]
    sql = Parity.stats_sql(:postgres, entry, start_at, stop_at, nil)
    assert sql =~ ~s[FROM platform."timeseries_metrics"]
    assert sql =~ "count(*)::bigint"
    assert sql =~ ~s[count(DISTINCT "series_key")]
    refute sql =~ "device_id"
    refute sql =~ "UNION ALL"
  end

  test "duckdb stats SQL reads published hive parquet only" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    glob = "s3://serviceradar-demo-analytics/analytics/v1/timeseries_metrics/date=*/*.parquet"

    sql =
      Parity.stats_sql(:duckdb, entry, ~U[2026-09-14 12:00:00Z], ~U[2026-09-14 18:00:00Z], glob)

    assert sql =~ "read_parquet"
    assert sql =~ "hive_partitioning := true"
    assert sql =~ glob
    refute sql =~ "_staging"
    refute sql =~ "fdw_primary"
  end

  test "compare requires equal counts and close averages" do
    a = %{row_count: 10, avg_value: 1.5, series_count: 3}
    assert :ok = Parity.compare(a, a)
    huge = %{row_count: 1, avg_value: 62_655_601_232.7612, series_count: 1}
    assert :ok = Parity.compare(huge, %{huge | avg_value: 62_655_601_232.67974})
    assert {:error, {:parity_mismatch, _}} = Parity.compare(a, %{a | row_count: 9})
    assert {:error, {:parity_mismatch, _}} = Parity.compare(a, %{a | avg_value: 2.0})
  end

  test "parquet glob is the published hive prefix" do
    cfg =
      Config.validate!(
        Config.load(
          driver: :pg_duckdb,
          storage: :s3,
          s3_bucket_url: "s3://serviceradar-demo-analytics",
          s3_access_key_id: "id",
          s3_secret_access_key: "secret",
          head_host: "analytics-head"
        )
      )

    assert {:ok, glob} = Parity.parquet_glob(cfg, "timeseries_metrics")

    assert glob ==
             "s3://serviceradar-demo-analytics/analytics/v1/timeseries_metrics/date=*/*.parquet"
  end
end
