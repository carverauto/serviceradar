defmodule ServiceRadar.AnalyticsStore.HeadTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Head
  alias ServiceRadar.ColdTier.Registry

  test "temp table and insert SQL follow the registry column list" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    sql = Head.create_temp_sql(entry)
    assert sql =~ "CREATE TEMP TABLE analytics_batch"
    # Postgrex commits each query; ON COMMIT DROP would drop the table before INSERT.
    refute sql =~ "ON COMMIT DROP"
    assert sql =~ ~s("timestamp" timestamptz)
    assert sql =~ ~s("tags" text)

    row = %{
      timestamp: ~U[2026-09-14 12:00:00Z],
      gateway_id: "gw-1",
      metric_name: "cpu",
      metric_type: "sysmon",
      value: 1.5
    }

    {insert_sql, params} = Head.insert_sql(entry, [row])
    assert insert_sql =~ "INSERT INTO analytics_batch"
    assert hd(params) == ~U[2026-09-14 12:00:00Z]
    assert "gw-1" in params
    assert 1.5 in params
  end

  test "copy SQL writes zstd parquet ordered by time and tiebreakers" do
    {:ok, entry} = Registry.fetch("timeseries_metrics")
    sql = Head.copy_sql(entry, "/tmp/staging.parquet")
    assert sql =~ "FORMAT parquet, COMPRESSION zstd"
    assert sql =~ ~s(ORDER BY "timestamp")
    assert sql =~ ~s("gateway_id")
    assert sql =~ ~s("series_key")
    assert sql =~ "/tmp/staging.parquet"
  end

  test "S3 secret SQL is path-style and bucket-scoped" do
    sql =
      Head.create_s3_secret_sql(%{
        access_key_id: "id",
        secret_access_key: "secret",
        region: "us-ord",
        endpoint: "us-ord-10.linodeobjects.com",
        url_style: "path",
        use_ssl: true,
        bucket_url: "s3://serviceradar-demo-analytics"
      })

    assert sql =~ "type := 'S3'"
    assert sql =~ "endpoint := 'us-ord-10.linodeobjects.com'"
    assert sql =~ "url_style := 'path'"
    assert sql =~ "use_ssl := 'true'"
    assert sql =~ "scope := 's3://serviceradar-demo-analytics'"
    refute sql =~ "serviceradar-control-plane-db-backups"
  end
end
