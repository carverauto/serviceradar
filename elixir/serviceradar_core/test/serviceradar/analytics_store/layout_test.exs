defmodule ServiceRadar.AnalyticsStore.LayoutTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.AnalyticsStore.Layout

  test "published keys sit under date= and staging keys do not" do
    keys = Layout.keys("timeseries_metrics", ~D[2026-09-14], "core-elx", "batch-1")

    assert keys.published_key ==
             "analytics/v1/timeseries_metrics/date=2026-09-14/core-elx-batch-1.parquet"

    assert keys.staging_key ==
             "analytics/v1/timeseries_metrics/_staging/batch-1.parquet"

    refute keys.published_key =~ "_staging"
  end

  test "published glob is hive date=* and never staging" do
    glob = Layout.published_glob("timeseries_metrics")
    assert glob == "analytics/v1/timeseries_metrics/date=*/*.parquet"
    refute glob =~ "_staging"
    refute Layout.published_glob("metrics/../x") =~ ".."
  end

  test "sanitizes table and batch fragments" do
    keys = Layout.keys("metrics/../x", ~D[2026-01-02], "core elx", "b 1")
    refute keys.published_key =~ ".."
    assert keys.published_key =~ "date=2026-01-02"
    assert keys.batch_id == "b-1"
  end

  test "partition_date reads atom or string timestamp keys" do
    dt = ~U[2026-09-14 15:04:05Z]
    assert {:ok, ~D[2026-09-14]} = Layout.partition_date(%{timestamp: dt}, "timestamp")
    assert {:ok, ~D[2026-09-14]} = Layout.partition_date(%{"timestamp" => dt}, "timestamp")
    assert {:error, {:unparseable_timestamp, nil}} = Layout.partition_date(%{}, "timestamp")
  end
end
