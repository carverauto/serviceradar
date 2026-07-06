defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query

  @moduletag :db_free

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
