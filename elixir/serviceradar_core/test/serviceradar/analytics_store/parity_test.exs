defmodule ServiceRadar.AnalyticsStore.ParityTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Config
  alias ServiceRadar.AnalyticsStore.Parity
  alias ServiceRadar.ColdTier.Registry

  @start ~U[2025-01-03 00:00:00Z]
  @stop ~U[2025-01-03 08:00:00Z]

  test "primary statistics use the same half-open interval as archive statistics" do
    entry = Registry.fetch!("timeseries_metrics")
    primary = Parity.stats_sql(:postgres, entry, @start, @stop, nil)

    archive =
      Parity.stats_sql(
        :duckdb,
        entry,
        @start,
        @stop,
        "s3://example-history/date=2025-01-03/fixture.parquet"
      )

    for sql <- [primary, archive] do
      assert sql =~ ~s["timestamp" >= TIMESTAMPTZ '2025-01-03T00:00:00Z']
      assert sql =~ ~s["timestamp" <  TIMESTAMPTZ '2025-01-03T08:00:00Z']
      assert sql =~ ~s[count(DISTINCT "series_key")]
      assert sql =~ "avg(value)::float8"
    end

    assert primary =~ ~s[FROM platform."timeseries_metrics"]
    assert archive =~ "read_parquet('s3://example-history/date=2025-01-03/fixture.parquet'"
  end

  test "archive URL quotes remain SQL literals" do
    sql =
      Parity.stats_sql(
        :duckdb,
        Registry.fetch!("timeseries_metrics"),
        @start,
        @stop,
        "s3://example-history/a'b.parquet"
      )

    assert sql =~ "a''b.parquet"
  end

  test "counts and series must match while averages allow only rounding noise" do
    expected = %{row_count: 12, avg_value: 8.0, series_count: 4}
    assert :ok = Parity.compare(expected, expected)
    assert :ok = Parity.compare(expected, %{expected | avg_value: 8.0000001})
    assert {:error, {:parity_mismatch, _}} = Parity.compare(expected, %{expected | row_count: 11})

    assert {:error, {:parity_mismatch, _}} =
             Parity.compare(expected, %{expected | series_count: 3})

    assert {:error, {:parity_mismatch, _}} =
             Parity.compare(expected, %{expected | avg_value: 8.1})

    large = %{expected | avg_value: 1_000_000_000.0}
    assert :ok = Parity.compare(large, %{large | avg_value: 1_000_000_000.5})

    assert {:error, {:parity_mismatch, _}} =
             Parity.compare(large, %{large | avg_value: 1_000_000_002.0})

    empty = %{row_count: 0, avg_value: nil, series_count: 0}
    assert :ok = Parity.compare(empty, empty)
    assert {:error, {:parity_mismatch, _}} = Parity.compare(empty, %{empty | avg_value: 0.0})
  end

  test "legacy parity glob uses the configured synthetic archive root" do
    config = Config.load(storage: :s3, s3_bucket_url: "s3://example-history")

    assert {:ok, "s3://example-history/analytics/v1/timeseries_metrics/date=*/*.parquet"} =
             Parity.parquet_glob(config, "timeseries_metrics")
  end
end
