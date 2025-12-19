defmodule ServiceRadarWebNGWeb.SRQLBuilderDownsampleTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder

  test "builds downsample tokens for timeseries metrics" do
    state =
      Builder.default_state("timeseries_metrics", 100)
      |> Map.put("filters", [])
      |> Map.put("time", "last_24h")
      |> Map.put("bucket", "5m")
      |> Map.put("agg", "avg")
      |> Map.put("series", "metric_name")

    query = Builder.build(state)
    assert query =~ "in:timeseries_metrics"
    assert query =~ "time:last_24h"
    assert query =~ "bucket:5m"
    assert query =~ "agg:avg"
    assert query =~ "series:metric_name"
  end

  test "parses downsample tokens for cpu metrics" do
    query = "in:cpu_metrics time:last_1h bucket:15s agg:max series:core_id limit:50"
    assert {:ok, builder} = Builder.parse(query)
    assert builder["entity"] == "cpu_metrics"
    assert builder["time"] == "last_1h"
    assert builder["bucket"] == "15s"
    assert builder["agg"] == "max"
    assert builder["series"] == "core_id"
    assert builder["limit"] == 50
  end

  test "rejects downsample tokens for non-metric entities" do
    query = "in:devices time:last_24h bucket:5m agg:avg series:uid limit:10"
    assert {:error, :downsample_not_supported} = Builder.parse(query)
  end
end
