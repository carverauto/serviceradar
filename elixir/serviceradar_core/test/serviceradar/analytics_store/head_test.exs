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

  test "S3 secret SQL escapes a synthetic scoped credential" do
    sql =
      Head.create_s3_secret_sql(%{
        access_key_id: "unit-access-key",
        secret_access_key: "synthetic'credential",
        region: "test-region-8",
        endpoint: "objects.example.com:9443",
        url_style: "path",
        use_ssl: false,
        bucket_url: "s3://unit-archive/telemetry"
      })

    assert sql =~ "type := 'S3'"
    assert sql =~ "key_id := 'unit-access-key'"
    assert sql =~ "secret := 'synthetic''credential'"
    assert sql =~ "region := 'test-region-8'"
    assert sql =~ "endpoint := 'objects.example.com:9443'"
    assert sql =~ "url_style := 'path'"
    assert sql =~ "use_ssl := 'false'"
    assert sql =~ "scope := 's3://unit-archive/telemetry'"
  end

  test "S3 secret action keeps an existing server instead of dropping it" do
    assert Head.s3_secret_action([]) == :create
    assert Head.s3_secret_action(["simple_s3_secret"]) == :keep
    assert Head.s3_secret_action(["simple_s3_secret_1"]) == :keep
    assert Head.s3_secret_action(["analytics_primary"]) == :create
  end

  test "after_connect accepts a DBConnection checkout struct, not only a pid" do
    conn = %DBConnection{pool_ref: nil, conn_ref: make_ref(), conn_mode: nil}
    assert :ok = Head.after_connect(conn)
    assert :ok = Head.after_connect(self())
  end
end
