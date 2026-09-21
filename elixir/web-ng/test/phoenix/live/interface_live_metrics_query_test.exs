defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery

  @moduletag :unit
  @moduletag :db_free

  test "sizes the bucket to the window so a chart is not sent points it cannot draw" do
    query =
      MetricsQuery.build_snmp_counter_query("device-1", 7, [
        "ifOutOctets",
        "ifInOctets",
        "ifInErrors"
      ])

    assert query =~ ~s(in:snmp_metrics)
    assert query =~ ~s(device_id:"device-1")
    assert query =~ "if_index:7"
    assert query =~ ~s(metric_name:["ifHCInOctets","ifHCOutOctets","ifInErrors","ifInOctets","ifOutOctets"])
    assert query =~ "time:last_24h"
    assert query =~ "bucket:5m"
    assert query =~ "agg:rate"
    assert query =~ "series:metric_name"
    assert query =~ "limit:7200"
  end

  test "follows the window and still honours an explicit bucket" do
    build = &MetricsQuery.build_snmp_counter_query("device-1", 7, ["ifInOctets"], &1)

    assert build.(time_range: "last_1h") =~ "bucket:15s"
    assert build.(time_range: "last_7d") =~ "bucket:1h"
    assert build.(time_range: "[2025-01-01T00:00:00Z,2025-01-31T00:00:00Z]") =~ "bucket:6h"
    assert build.(time_range: "last_24h", bucket: "1m") =~ "bucket:1m"
    assert build.(time_range: "last_24h", bucket: nil) =~ "bucket:5m"
  end

  test "sizes row limit from unique selected metrics including 64-bit aliases" do
    assert MetricsQuery.row_limit(["ifInOctets", "ifInOctets", "ifOutOctets"]) == 5_760
    assert MetricsQuery.row_limit(Enum.map(1..12, &"metric#{&1}")) == 17_280
  end

  test "escapes query values and omits empty metric filter" do
    query = MetricsQuery.build_snmp_counter_query(~s(device"\\1), 3, [nil, "", "Unknown"])

    assert query =~ ~s(device_id:"device\\"\\\\1")
    assert query =~ "bucket:5m"
    assert query =~ "limit:3600"
    refute query =~ "metric_name:"
  end
end
