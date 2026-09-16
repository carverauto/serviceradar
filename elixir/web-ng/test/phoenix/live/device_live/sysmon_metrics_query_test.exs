defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query

  @moduletag :db_free

  test "requested chart bounds are pinned independently of sparse returned samples" do
    now = ~U[2025-04-01 00:00:00Z]
    assert Query.requested_window("last_90d", now) == {~U[2025-01-01 00:00:00Z], now}
    assert Query.requested_window("[2025-01-01T00:00:00Z,2025-04-01T00:00:00Z]", now) == {~U[2025-01-01 00:00:00Z], now}
    assert Query.requested_window("[2025-04-01T00:00:00Z,2025-01-01T00:00:00Z]", now) == nil
    assert Query.requested_window("last_0d", now) == nil
    assert Query.requested_window(nil, now) == nil
  end

  describe "bucket_for_time_range/1" do
    test "sizes the bucket to relative windows so short views get fine points" do
      assert Query.bucket_for_time_range("last_1h") == "15s"
      assert Query.bucket_for_time_range("last_6h") == "2m"
      # 24h keeps the familiar 5m bucket (~288 points).
      assert Query.bucket_for_time_range("last_24h") == "5m"
      assert Query.bucket_for_time_range("last_7d") == "1h"
    end

    test "sizes the bucket from an absolute range window" do
      assert Query.bucket_for_time_range("[2026-06-26T06:30:00Z,2026-06-26T08:30:00Z]") == "30s"
    end

    test "falls back to 5m for unparseable or empty ranges" do
      assert Query.bucket_for_time_range("") == "5m"
      assert Query.bucket_for_time_range("nonsense") == "5m"
      assert Query.bucket_for_time_range(nil) == "5m"
      assert Query.bucket_for_time_range("[bad,range]") == "5m"
    end

    test "coarsens gracefully for very large windows" do
      assert Query.bucket_for_time_range("last_30d") == "6h"
      assert Query.bucket_for_time_range("last_90d") == "12h"
    end
  end

  test "chart bucket metadata reflects the actual query, including a custom override" do
    assert Query.query_bucket_seconds("in:timeseries_metrics bucket:12h agg:avg") == 43_200
    assert Query.query_bucket_seconds("in:timeseries_metrics bucket:15s agg:avg") == 15
    assert Query.query_bucket_seconds("in:timeseries_metrics") == nil
  end

  test "custom ranges reserve an inclusive boundary point and scale beyond one year" do
    for duration <- [4_500, 30 * 86_400, 90 * 86_400, 400 * 86_400, 5 * 365 * 86_400] do
      start_time = ~U[2025-01-01 09:23:17Z]
      end_time = DateTime.add(start_time, duration)
      range = "[#{DateTime.to_iso8601(start_time)},#{DateTime.to_iso8601(end_time)}]"
      bucket = range |> Query.bucket_for_time_range() |> Query.bucket_seconds()
      count = div(DateTime.to_unix(end_time), bucket) - div(DateTime.to_unix(start_time), bucket) + 1
      assert count <= 300
    end
  end

  describe "device_uid_filter_tokens/1" do
    test "returns no token for an empty UID list" do
      assert Query.device_uid_filter_tokens([]) == []
    end

    test "uses an exact match for a single UID" do
      assert Query.device_uid_filter_tokens(["sr:host:abc"]) == [~s(uid:"sr:host:abc")]
    end

    test "collapses a merged device's UIDs into an SRQL IN list" do
      assert Query.device_uid_filter_tokens(["sr:host:new", "sr:host:old-1", "sr:host:old-2"]) ==
               [~s|uid:("sr:host:new","sr:host:old-1","sr:host:old-2")|]
    end

    test "escapes embedded quotes and backslashes in UID values" do
      assert Query.device_uid_filter_tokens([~s(a"b), ~s(c\\d)]) ==
               [~s|uid:("a\\"b","c\\\\d")|]
    end
  end
end
