defmodule ServiceRadar.AnalyticsStore.ViewsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Views
  alias ServiceRadar.ColdTier.Registry

  defp config(extra \\ []) do
    Config.load(
      Keyword.merge(
        [
          driver: :pg_duckdb,
          tables: ["timeseries_metrics"],
          storage: :s3,
          s3_bucket_url: "s3://synthetic-history",
          s3_endpoint: "objects.example.com",
          s3_access_key_id: "fixture-access",
          s3_secret_access_key: "fixture-secret",
          head_host: "analytics.example.com"
        ],
        extra
      )
    )
  end

  test "maintenance view reads published partitions" do
    sql = Views.view_sql(config(), Registry.fetch!("timeseries_metrics"))
    assert sql =~ "s3://synthetic-history/analytics/v1/timeseries_metrics/date=*/*.parquet"
    assert sql =~ "hive_partitioning := true"
    refute sql =~ "_staging"
    refute sql =~ "postgres_fdw"
    refute sql =~ "UNION ALL"
  end

  test "interactive scan enumerates only supplied objects and handles SQL quotes" do
    entry = Registry.fetch!("timeseries_metrics")

    urls = [
      "s3://synthetic-history/analytics/v1/timeseries_metrics/date=2025-02-01/batch'a.parquet"
    ]

    sql = Views.manifest_select_sql(entry, urls)
    assert sql =~ "batch''a.parquet"
    refute sql =~ "ROW_NUMBER"
    refute sql =~ "date=*"
    refute sql =~ "_staging"
  end

  test "empty selection stays empty without opening any files" do
    sql = Views.manifest_select_sql(Registry.fetch!("timeseries_metrics"), [])
    assert sql =~ "WHERE false"
    assert sql =~ ~s[CAST(NULL AS TIMESTAMPTZ) AS "timestamp"]
    refute sql =~ "read_parquet"
  end

  test "other archive table projections retain their existing semantics" do
    entry = Registry.fetch!("ocsf_network_activity")
    cfg = config(storage: :filesystem, filesystem_path: "/tmp/synthetic-archive")
    sql = Views.view_sql(cfg, entry)
    assert sql =~ "/tmp/synthetic-archive/analytics/v1/ocsf_network_activity/date=*/*.parquet"
    refute sql =~ "_analytics_row"
  end

  test "hybrid provisions exactly the named archive view without disabling the hot store" do
    cfg = config(driver: :hybrid)
    owner = self()

    query = fn _, sql, _ ->
      send(owner, {:sql, sql})
      :ok
    end

    assert :ok = Views.ensure_all(:connection, cfg, query: query)
    assert Config.flipped_tables(cfg) == []
    assert_received {:sql, "CREATE SCHEMA IF NOT EXISTS platform"}
    assert_received {:sql, "BEGIN"}
    assert_received {:sql, ~s(DROP VIEW IF EXISTS platform."timeseries_metrics")}
    assert_received {:sql, sql}
    assert sql =~ ~s(CREATE VIEW platform."timeseries_metrics")
    assert_received {:sql, "COMMIT"}
    refute_received {:sql, _}
  end
end
