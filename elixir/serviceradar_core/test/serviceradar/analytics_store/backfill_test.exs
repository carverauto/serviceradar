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
        s3_bucket_url: "s3://example-backfill-fixtures",
        s3_access_key_id: "fixture-access-key",
        s3_secret_access_key: "fixture-secret-key",
        s3_endpoint: "objects.example.com",
        s3_region: "unit-region-3",
        head_host: "analytics.example.com"
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

  test "FDW SQL uses the supplied primary and registry schema" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")

    sql =
      Backfill.ensure_fdw_sql(entry, %{
        host: "primary.example.com",
        port: 5439,
        database: "fixture_catalog",
        username: "fixture_owner",
        password: "invented'password"
      })

    assert sql =~ "CREATE EXTENSION IF NOT EXISTS postgres_fdw"
    assert sql =~ "host 'primary.example.com', port '5439', dbname 'fixture_catalog'"
    assert sql =~ "user 'fixture_owner', password 'invented''password'"
    assert sql =~ ~s[CREATE FOREIGN TABLE analytics_src."timeseries_metrics"]
    assert sql =~ ~s["tags" jsonb]
  end

  test "copy SQL reads the foreign table for one UTC day and publishes" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    keys = Backfill.partition_keys("timeseries_metrics", ~D[2031-04-20])
    staging = "s3://example-backfill-fixtures/" <> keys.staging_key
    published = "s3://example-backfill-fixtures/" <> keys.published_key

    assert {:ok, sql} =
             Backfill.copy_partition_sql(cfg(), entry, ~D[2031-04-20], staging, published)

    assert sql =~ ~s[FROM analytics_src."timeseries_metrics"]
    assert sql =~ "TIMESTAMPTZ '2031-04-20 00:00:00+00'"
    assert sql =~ "TIMESTAMPTZ '2031-04-21 00:00:00+00'"
    assert sql =~ staging
    assert sql =~ published
    assert sql =~ "_staging"
    assert sql =~ "date=2031-04-20"
    refute sql =~ "UNION ALL"
  end

  test "run stops on a count mismatch without recording a manifest" do
    copy = fn _entry, ~D[2031-04-20], 7, _staging, _published, _opts -> {:ok, 6} end

    assert {:error, {:count_mismatch, ~D[2031-04-20], 7, 6}} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [%{date: ~D[2031-04-20], count: 7}],
               copy: copy,
               record_manifest: fn _attrs -> flunk("an unverified copy became query-visible") end
             )
  end

  test "run records verified published partitions and sums their counts" do
    copy = fn _entry, date, expected, staging, published, _opts ->
      assert staging =~ "_staging"
      refute published =~ "_staging"
      send(self(), {:verified_copy, date})
      {:ok, expected}
    end

    record = fn attrs ->
      assert_received {:verified_copy, date}
      assert attrs.partition_date == date
      send(self(), {:manifest, attrs})
      :ok
    end

    assert {:ok, 11} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [
                 %{date: ~D[2031-04-20], count: 7},
                 %{date: ~D[2031-04-21], count: 4}
               ],
               copy: copy,
               record_manifest: record
             )

    assert_received {:manifest,
                     %{
                       table_name: "timeseries_metrics",
                       object_key:
                         "analytics/v1/timeseries_metrics/date=2031-04-20/backfill-2031-04-20.parquet",
                       staging_key: "analytics/v1/timeseries_metrics/_staging/2031-04-20.parquet",
                       partition_date: ~D[2031-04-20],
                       row_count: 7,
                       batch_id: "2031-04-20",
                       status: :published
                     }}

    assert_received {:manifest,
                     %{partition_date: ~D[2031-04-21], row_count: 4, status: :published}}

    refute_received {:manifest, _}
  end

  test "copy failure never publishes a manifest" do
    assert {:error, :copy_failed} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [%{date: ~D[2031-04-20], count: 7}],
               copy: fn _, _, _, _, _, _ -> {:error, :copy_failed} end,
               record_manifest: fn _attrs -> flunk("a failed copy became query-visible") end
             )
  end

  test "manifest failure is returned before the next partition is copied" do
    assert {:error, :manifest_unavailable} =
             Backfill.run("timeseries_metrics",
               config: cfg(),
               partitions: [
                 %{date: ~D[2031-04-20], count: 7},
                 %{date: ~D[2031-04-21], count: 4}
               ],
               copy: fn _, ~D[2031-04-20], 7, _, _, _ -> {:ok, 7} end,
               record_manifest: fn _attrs -> {:error, :manifest_unavailable} end
             )
  end

  test "unknown table is rejected" do
    assert {:error, {:unknown_analytics_table, "not_a_table"}} = Backfill.run("not_a_table")
  end

  test "range keys sit in the hive day and do not reuse the whole-day backfill object" do
    start_at = ~U[2033-02-12 09:20:00Z]
    stop_at = ~U[2033-02-12 11:15:00Z]
    day = Backfill.partition_keys("timeseries_metrics", ~D[2033-02-12])
    range = Backfill.range_keys("timeseries_metrics", start_at, stop_at)

    assert range.partition_date == ~D[2033-02-12]
    assert range.published_key =~ "date=2033-02-12/"
    refute range.published_key == day.published_key
    refute range.batch_id == day.batch_id
  end

  test "range COPY SQL is half-open and rejects an empty window" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    start_at = ~U[2033-02-12 09:20:00Z]
    stop_at = ~U[2033-02-12 11:15:00Z]
    keys = Backfill.range_keys("timeseries_metrics", start_at, stop_at)
    staging = "s3://example-backfill-fixtures/" <> keys.staging_key
    published = "s3://example-backfill-fixtures/" <> keys.published_key

    assert {:ok, sql} =
             Backfill.copy_range_sql(cfg(), entry, start_at, stop_at, staging, published)

    assert sql =~ "TIMESTAMPTZ '2033-02-12T09:20:00Z'"
    assert sql =~ "TIMESTAMPTZ '2033-02-12T11:15:00Z'"
    assert sql =~ staging
    assert sql =~ published
    refute sql =~ "UNION ALL"

    assert {:error, :empty_range} =
             Backfill.copy_range_sql(cfg(), entry, stop_at, start_at, staging, published)
  end
end
