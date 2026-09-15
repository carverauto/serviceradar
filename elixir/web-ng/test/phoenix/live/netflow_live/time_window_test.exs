defmodule ServiceRadarWebNGWeb.NetflowLive.TimeWindowTest do
  use ExUnit.Case, async: true

  alias ServiceRadarSRQL.Native
  alias ServiceRadarWebNGWeb.NetflowLive.Visualize.TimeWindow

  @moduletag :db_free

  test "long windows fit every inclusive bucket in the chart query limit" do
    for {days, expected_bucket} <- [{7, 7_200}, {30, 43_200}, {90, 86_400}, {390, 345_600}],
        start_time <- [~U[2025-01-01 00:00:00Z], ~U[2025-01-01 09:23:17.123456Z]] do
      end_time = DateTime.add(start_time, days, :day)
      bucket = TimeWindow.chart_bucket_seconds(start_time, end_time)
      assert bucket == expected_bucket
      first_bucket = div(DateTime.to_unix(start_time, :microsecond), bucket * 1_000_000)
      last_bucket = div(DateTime.to_unix(end_time, :microsecond), bucket * 1_000_000)
      assert last_bucket - first_bucket + 1 <= 120

      query =
        "in:flows src_ip:192.0.2.7 time:[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}] bucket:#{div(bucket, 60)}m agg:sum value_field:bytes_total limit:120"

      assert {:ok, _} = Native.translate(query, 120, nil, "next", nil, nil)
    end
  end

  test "existing short-window resolutions remain unchanged" do
    start_time = ~U[2025-01-01 00:00:00Z]

    for {hours, bucket} <- [{1, 60}, {6, 300}, {24, 900}] do
      assert TimeWindow.chart_bucket_seconds(start_time, DateTime.add(start_time, hours * 3_600)) == bucket
    end
  end
end
