defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsQueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.InterfaceLive.MetricsQuery

  @moduletag :unit
  @moduletag :db_free

  test "requested display bounds preserve the chosen duration and relative query routing" do
    now = ~U[2025-04-01 12:00:00Z]
    assert MetricsQuery.requested_window("last_90d", now) == {~U[2025-01-01 12:00:00Z], now}
    assert MetricsQuery.requested_window("last_30d", now) == {~U[2025-03-02 12:00:00Z], now}
    assert MetricsQuery.requested_window("invalid", now) == {~U[2025-03-31 12:00:00Z], now}

    query =
      MetricsQuery.build_snmp_counter_query("synthetic-device", 7, ["ifInOctets"], MetricsQuery.window_opts("last_90d"))

    assert query =~ "time:last_90d"
  end

  test "long history windows use bounded coarse buckets without changing the default" do
    for {range, bucket} <- [{"last_24h", "1m"}, {"last_30d", "6h"}, {"last_90d", "12h"}] do
      query =
        MetricsQuery.build_snmp_counter_query("synthetic-device", 7, ["ifInOctets"], MetricsQuery.window_opts(range))

      assert query =~ "time:#{range} bucket:#{bucket}"
      assert query =~ "if_index:7"
      assert query =~ "agg:rate series:metric_name"
    end
  end

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

  test "batches distinct interfaces with enough rows for the full metric union" do
    query =
      MetricsQuery.build_snmp_counter_batch_query("device-1", [
        %{if_index: 8, metrics_selected: ["ifOutOctets", "metric:packets"]},
        %{if_index: 7, metrics_selected: ["ifInOctets"]},
        %{if_index: 7, metrics_selected: ["ifInOctets"]}
      ])

    assert query =~ "if_index:(7,8)"
    assert query =~ ~s(metric_name:["ifHCInOctets","ifHCOutOctets","ifInOctets","ifOutOctets","metric:packets"])
    assert query =~ "time:last_24h bucket:1m agg:rate series:interface_metric limit:14410"
  end

  test "single-interface query retains its existing series and limit contract" do
    assert MetricsQuery.build_snmp_counter_query("device-1", 7, ["ifInOctets"]) ==
             ~s(in:snmp_metrics device_id:"device-1" if_index:7 metric_name:["ifHCInOctets","ifInOctets"] time:last_24h bucket:1m agg:rate series:metric_name limit:3600)
  end
end
