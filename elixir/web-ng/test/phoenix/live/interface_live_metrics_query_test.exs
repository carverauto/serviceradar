defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery

  @moduletag :unit
  @moduletag :db_free

  test "uses one-minute buckets for interface counter charts" do
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
    assert query =~ "bucket:1m"
    assert query =~ "agg:rate"
    assert query =~ "series:metric_name"
    assert query =~ "limit:7200"
    refute query =~ "bucket:5m"
  end

  test "sizes row limit from unique selected metrics including 64-bit aliases" do
    assert MetricsQuery.row_limit(["ifInOctets", "ifInOctets", "ifOutOctets"]) == 5_760
    assert MetricsQuery.row_limit(Enum.map(1..12, &"metric#{&1}")) == 17_280
  end

  test "escapes query values and omits empty metric filter" do
    query = MetricsQuery.build_snmp_counter_query(~s(device"\\1), 3, [nil, "", "Unknown"])

    assert query =~ ~s(device_id:"device\\"\\\\1")
    assert query =~ "bucket:1m"
    assert query =~ "limit:3600"
    refute query =~ "metric_name:"
  end
end
