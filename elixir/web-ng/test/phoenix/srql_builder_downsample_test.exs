defmodule ServiceRadarWebNGWeb.SRQLBuilderDownsampleTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.Builder

  @moduletag :db_free

  test "builds downsample tokens for timeseries metrics" do
    state =
      "timeseries_metrics"
      |> Builder.default_state(100)
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

  test "flows chart + cidr parses and rebuilds without dropping legal filters" do
    query =
      "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total series:app " <>
        "cidr:10.0.0.0/8 limit:100"

    assert {:ok, state} = Builder.parse(query)
    assert state["bucket"] == "5m"
    assert Enum.any?(state["filters"], &(&1["field"] == "cidr"))

    rebuilt = Builder.build(state)
    assert rebuilt =~ "bucket:5m"
    assert rebuilt =~ "cidr:10.0.0.0/8"
  end

  test "flows chart + tag is rejected instead of silently desynchronizing the builder" do
    query =
      "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total series:app " <>
        "tag:edge limit:100"

    assert {:error, {:unsupported_mode_filter_fields, ["tag"]}} = Builder.parse(query)
  end
end
