defmodule ServiceRadar.AnalyticsStore.BackfillTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Backfill
  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.ColdTier.Registry

  defp cfg do
    Config.validate!(
      Config.load(
        driver: :pg_duckdb,
        storage: :s3,
        s3_bucket_url: "s3://serviceradar-demo-analytics",
        s3_access_key_id: "id",
        s3_secret_access_key: "secret",
        s3_endpoint: "us-ord-10.linodeobjects.com",
        head_host: "analytics-head"
      )
    )
  end

  test "partition SQL groups by UTC date and does not select payloads" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    sql = Backfill.partition_count_sql(entry)
    assert sql =~ ~s["timestamp" AT TIME ZONE 'UTC']
    assert sql =~ ~s[FROM platform."timeseries_metrics"]
    assert sql =~ "count(*)::bigint"
    refute sql =~ "device_id"
    refute sql =~ "tags"
  end

  test "FDW SQL is schema-qualified and not the backup bucket" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")

    sql =
      Backfill.ensure_fdw_sql(entry, %{
        host: "cnpg-rw.demo.svc.cluster.local",
        username: "serviceradar",
        password: "not-a-real-password"
      })

    assert sql =~ "CREATE EXTENSION IF NOT EXISTS postgres_fdw"
    assert sql =~ "host 'cnpg-rw.demo.svc.cluster.local'"
    assert sql =~ ~s[CREATE FOREIGN TABLE analytics_src."timeseries_metrics"]
    assert sql =~ ~s["tags" jsonb]
    refute sql =~ "serviceradar-control-plane-db-backups"
  end

  test "copy SQL reads the foreign table for one UTC day and publishes" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    keys = Backfill.partition_keys("timeseries_metrics", ~D[2026-09-07])
    staging = "s3://serviceradar-demo-analytics/" <> keys.staging_key
    published = "s3://serviceradar-demo-analytics/" <> keys.published_key

    assert {:ok, sql} =
             Backfill.copy_partition_sql(cfg(), entry, ~D[2026-09-07], staging, published)

    assert sql =~ ~s[FROM analytics_src."timeseries_metrics"]
    assert sql =~ "TIMESTAMPTZ '2026-09-07 00:00:00+00'"
    assert sql =~ "TIMESTAMPTZ '2026-09-08 00:00:00+00'"
    assert sql =~ staging
    assert sql =~ published
    assert sql =~ "_staging"
    assert sql =~ "date=2026-09-07"
    refute sql =~ "UNION ALL"
  end

  test "run stops on a count mismatch" do
    copy = fn _entry, ~D[2026-09-07], 10, _staging, _published, _opts -> {:ok, 9} end

    assert {:error, {:count_mismatch, ~D[2026-09-07], 10, 9}} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [%{date: ~D[2026-09-07], count: 10}],
               copy: copy
             )
  end

  test "run sums matching partitions and skips EventWriter" do
    copy = fn _entry, _date, expected, staging, published, _opts ->
      assert staging =~ "_staging"
      assert published =~ "date="
      {:ok, expected}
    end

    assert {:ok, 15} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [
                 %{date: ~D[2026-09-07], count: 10},
                 %{date: ~D[2026-09-08], count: 5}
               ],
               copy: copy
             )
  end

  test "unknown table is rejected" do
    assert {:error, {:unknown_analytics_table, "not_a_table"}} = Backfill.run("not_a_table")
  end

  test "range keys sit in the hive day and do not reuse the whole-day backfill object" do
    start_at = ~U[2026-09-15 00:00:00Z]
    stop_at = ~U[2026-09-15 06:00:00Z]
    day = Backfill.partition_keys("timeseries_metrics", ~D[2026-09-15])
    range = Backfill.range_keys("timeseries_metrics", start_at, stop_at)

    assert range.partition_date == ~D[2026-09-15]
    assert range.published_key =~ "date=2026-09-15/"
    refute range.published_key == day.published_key
    refute range.batch_id == day.batch_id
  end

  test "range COPY SQL is half-open and rejects an empty window" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    start_at = ~U[2026-09-15 00:00:00Z]
    stop_at = ~U[2026-09-15 06:53:00Z]
    keys = Backfill.range_keys("timeseries_metrics", start_at, stop_at)
    staging = "s3://serviceradar-demo-analytics/" <> keys.staging_key
    published = "s3://serviceradar-demo-analytics/" <> keys.published_key

    assert {:ok, sql} =
             Backfill.copy_range_sql(cfg(), entry, start_at, stop_at, staging, published)

    assert sql =~ "TIMESTAMPTZ '2026-09-15T00:00:00Z'"
    assert sql =~ "TIMESTAMPTZ '2026-09-15T06:53:00Z'"
    assert sql =~ staging
    assert sql =~ published
    refute sql =~ "UNION ALL"

    assert {:error, :empty_range} =
             Backfill.copy_range_sql(cfg(), entry, stop_at, start_at, staging, published)
  end
end
