defmodule ServiceRadar.AnalyticsStore.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Query
  alias ServiceRadar.AnalyticsStore.SQL

  @key "analytics/v1/timeseries_metrics/date=2025-01-02/writer-batch_a.parquet"

  test "SRQL resolves its pinned UTC window against published manifest files before head planning" do
    translation = %{
      "dialect" => "duckdb",
      "analytics_table" => "timeseries_metrics",
      "time_range" => %{"start" => "2025-01-02T23:30:00Z", "end" => "2025-01-03T00:30:00Z"},
      "params" => [%{"t" => "timestamptz"}, %{"t" => "timestamptz"}],
      "sql" => "SELECT value FROM timeseries_metrics WHERE timestamp >= $1 AND timestamp < $2"
    }

    list = fn "timeseries_metrics", ~D[2025-01-02], ~D[2025-01-03] -> {:ok, [@key]} end

    assert {:ok, sql, []} =
             SQL.prepare_translation(
               translation,
               [~U[2025-01-02 23:30:00Z], ~U[2025-01-03 00:30:00Z]],
               config: config(),
               manifest_list_fn: list
             )

    assert sql =~ ~s(WITH "timeseries_metrics" AS NOT MATERIALIZED)
    assert sql =~ "read_parquet(ARRAY['s3://analytics.example/#{@key}']::text[]"
    assert sql =~ "SELECT value FROM timeseries_metrics WHERE timestamp >= "
    assert sql =~ "2025-01-02"
    assert sql =~ "2025-01-03"
    refute sql =~ "$1"
    assert sql =~ "hive_partitioning := true"
    assert sql =~ ~s/CAST(r['value'] AS float8) AS "value"/
    refute sql =~ "date=*"
  end

  test "scoped sources preserve counter-rate CTEs, explicit aliases and literal text" do
    original = """
    WITH ordered_data AS (
      SELECT m.value, 'platform.timeseries_metrics' AS label
      FROM platform.timeseries_metrics AS m
      -- platform.timeseries_metrics is mentioned in a comment
      WHERE m.timestamp >= $1
    ), rate_data AS (SELECT * FROM ordered_data)
    SELECT * FROM rate_data
    """

    assert {:ok, sql} = prepare(original, [@key])
    assert sql =~ ", ordered_data AS ("
    assert sql =~ "FROM timeseries_metrics AS m"
    assert sql =~ "'platform.timeseries_metrics' AS label"
    assert sql =~ "-- platform.timeseries_metrics is mentioned in a comment"
    assert sql =~ "rate_data AS (SELECT * FROM ordered_data)"
    assert sql =~ "WHERE m.timestamp >= $1"
  end

  test "quoted table identifiers use the scoped CTE too" do
    assert {:ok, sql} = prepare(~s(SELECT value FROM "platform"."timeseries_metrics"), [@key])
    assert sql =~ "SELECT value FROM timeseries_metrics"
  end

  test "no published files produces a typed empty relation and no object-store operation" do
    assert {:ok, sql} = prepare("SELECT count(*) FROM timeseries_metrics", [])
    assert sql =~ ~s/CAST(NULL AS float8) AS "value"/
    assert sql =~ ~s/CAST(NULL AS DATE) AS "_partition_date" WHERE false/
    assert sql =~ "SELECT count(*) FROM timeseries_metrics"
    refute sql =~ "read_parquet"
  end

  test "manifest failures fail closed rather than producing an empty result" do
    assert {:error, :manifest_unavailable} =
             Query.prepare(
               "timeseries_metrics",
               "SELECT value FROM timeseries_metrics",
               {nil, nil},
               config: config(),
               manifest_list_fn: fn _, _, _ -> {:error, :manifest_unavailable} end
             )
  end

  test "manifest keys cannot reintroduce a glob, staging prefix, or path traversal" do
    for key <- [
          "analytics/v1/timeseries_metrics/date=*/*.parquet",
          "analytics/v1/timeseries_metrics/_staging/batch.parquet",
          "analytics/v1/timeseries_metrics/date=2025-01-01/../date=2025-01-02/a.parquet",
          "analytics/v1/other_table/date=2025-01-02/a.parquet"
        ] do
      assert {:error, :invalid_analytics_manifest_key} = prepare("SELECT 1", [key])
    end
  end

  test "an upper-bound timestamp parameter never excludes historical manifest files" do
    historical = "analytics/v1/timeseries_metrics/date=2024-12-01/writer-history.parquet"
    list = fn "timeseries_metrics", nil, nil -> {:ok, [historical, @key]} end

    assert {:ok, sql, []} =
             SQL.prepare_query(
               "timeseries_metrics",
               "SELECT value FROM timeseries_metrics WHERE timestamp < $1",
               [~U[2025-01-03 12:00:00Z]],
               config: config(),
               manifest_list_fn: list
             )

    assert sql =~ historical
    assert sql =~ @key
    assert sql =~ "WHERE timestamp < TIMESTAMPTZ"
  end

  test "a direct caller can provide the UTC window it owns explicitly" do
    list = fn "timeseries_metrics", ~D[2025-01-02], nil -> {:ok, [@key]} end
    cutoff = ~U[2025-01-02 12:00:00Z]

    assert {:ok, sql, []} =
             SQL.prepare_query(
               "timeseries_metrics",
               "SELECT value FROM timeseries_metrics WHERE timestamp >= $1",
               [cutoff],
               config: config(),
               manifest_list_fn: list,
               time_range: {cutoff, nil}
             )

    assert sql =~ @key
    assert sql =~ "WHERE timestamp >= TIMESTAMPTZ"
  end

  test "direct query windows normalize datetime offsets to UTC partition dates" do
    shifted = DateTime.from_naive!(~N[2025-01-03 01:00:00], "Etc/UTC")
    shifted = %{shifted | utc_offset: 7200, zone_abbr: "UTC+2", time_zone: "Etc/GMT-2"}

    assert {:ok, {~D[2025-01-02], nil}} = Query.query_window(time_range: {shifted, nil})
    assert {:ok, {nil, nil}} = Query.query_window([])
    assert {:error, :invalid_analytics_time_range} = Query.query_window(time_range: "last_1h")
  end

  test "postgres SQL is unchanged and never lists the manifest" do
    translation = %{"sql" => "SELECT value FROM platform.timeseries_metrics"}

    assert {:ok, "SELECT value FROM platform.timeseries_metrics", []} =
             SQL.prepare_translation(translation, [],
               manifest_list_fn: fn _, _, _ -> flunk("must not read manifest") end
             )
  end

  test "a duckdb translation without physical source metadata fails closed" do
    assert {:error, :missing_analytics_source} =
             SQL.prepare_translation(%{"dialect" => "duckdb", "sql" => "SELECT 1"}, [])
  end

  defp prepare(sql, keys) do
    Query.prepare("timeseries_metrics", sql, {~D[2025-01-02], ~D[2025-01-02]},
      config: config(),
      manifest_list_fn: fn _, _, _ -> {:ok, keys} end
    )
  end

  defp config do
    Config.load(driver: :pg_duckdb, storage: :s3, s3_bucket_url: "s3://analytics.example")
  end
end
