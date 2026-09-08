defmodule ServiceRadarWebNGWeb.Components.TimeseriesAggregationTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.SeriesData
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec

  @moduletag :unit
  @moduletag :db_free

  test "extracts disk rows as mount point series when viz omits a series field" do
    rows = [
      %{"timestamp" => "2025-01-01T00:00:00Z", "value" => 70.0, "mount_point" => "/"},
      %{"timestamp" => "2025-01-01T00:05:00Z", "value" => 72.0, "mount_point" => "/"},
      %{"timestamp" => "2025-01-01T00:00:00Z", "value" => 61.0, "mount_point" => "/var"}
    ]

    assert {:ok, series_points, _series_units, _series_metadata} =
             Spec.extract_series_points(rows, %{x: "timestamp", y: "value", series: nil})

    assert Enum.map(series_points, &elem(&1, 0)) == ["/", "/var"]
  end

  test "extracts CPU rows as core series and falls back to series_key" do
    rows = [
      %{"timestamp" => "2025-01-01T00:00:00Z", "value" => 42.0, "core_id" => 0},
      %{"timestamp" => "2025-01-01T00:00:00Z", "value" => 84.0, "core_id" => 1}
    ]

    assert {:ok, series_points, _series_units, _series_metadata} =
             Spec.extract_series_points(rows, %{x: "timestamp", y: "value", series: nil})

    assert Enum.map(series_points, &elem(&1, 0)) == ["0", "1"]

    fallback_rows = [
      %{
        "timestamp" => "2025-01-01T00:00:00Z",
        "value" => 51.0,
        "series_key" => "sysmon.cpu:host:CPU1"
      }
    ]

    assert {:ok, fallback_series, _series_units, _series_metadata} =
             Spec.extract_series_points(fallback_rows, %{x: "timestamp", y: "value", series: nil})

    assert Enum.map(fallback_series, &elem(&1, 0)) == ["sysmon.cpu:host:CPU1"]
  end

  test "series stats are computed from raw rows instead of downsampled chart points" do
    start_dt = ~U[2025-01-01 00:00:00Z]

    points =
      for idx <- 0..999 do
        value = if idx == 999, do: 100.0, else: 0.0
        {DateTime.add(start_dt, idx, :second), value}
      end

    [series] =
      SeriesData.build_series_data(
        [{"disk", points}],
        %{y: "used_percent"},
        :none,
        false,
        nil
      )

    assert length(series.point_data) < length(points)
    assert series.paths.min == 0.0
    assert series.paths.max == 100.0
    assert series.paths.avg == 0.1
    assert series.paths.latest == 100.0
  end

  test "humanizes 64-bit packet counters the same as 32-bit names" do
    assert Metrics.humanize_series_name("ifHCInUcastPkts") == "Inbound Packets"
    assert Metrics.humanize_series_name("ifHCOutUcastPkts") == "Outbound Packets"
    assert Metrics.humanize_series_name("ifInUcastPkts::ifindex:21") == "Inbound Packets"
    assert Metrics.traffic_series?("ifHCInOctets::ifindex:21")
  end

  test "can extract more than the default six series when asked" do
    rows =
      for idx <- 1..8 do
        %{
          "timestamp" => "2025-01-01T00:00:00Z",
          "value" => idx * 1.0,
          "metric_name" => "metric#{idx}"
        }
      end

    spec = %{x: "timestamp", y: "value", series: "metric_name"}

    assert {:ok, default_series, _, _} = Spec.extract_series_points(rows, spec)
    assert length(default_series) == 6

    assert {:ok, all_series, _, _} = Spec.extract_series_points(rows, spec, max_series: 32)
    assert length(all_series) == 8
  end
end
