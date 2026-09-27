defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.TelemetryMetricsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics
  alias ServiceRadar.Repo

  @moduletag :integration

  test "topology recovers 32-bit counter wraps and drops resets" do
    uid = "sr:wrap-#{Ecto.UUID.generate()}"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    previous = DateTime.add(now, -10, :second)
    half_second = DateTime.add(now, -500, :millisecond)
    modulus = 4_294_967_296.0

    samples = [
      # 32-bit wrap: 100 packets after the wrap plus 900 before it, over 10s.
      {1, "ifInUcastPkts", 32, previous, modulus - 900.0, now, 100.0},
      # 32-bit decrease inside half a second: a wrap would imply over 2^32 packets/s.
      {2, "ifInUcastPkts", 32, half_second, 3_000_000.0, now, 40.0},
      # 64-bit counter decrease with no ceiling and a large previous value: reset.
      {3, "ifHCInUcastPkts", 64, previous, 9_000_000_000.0, now, 40.0},
      # Unknown width, previous value fits in 32 bits: treated as a wrap.
      {4, "ifInUcastPkts", nil, previous, modulus - 400.0, now, 100.0}
    ]

    rows =
      Enum.flat_map(samples, fn {index, name, width, at_a, value_a, at_b, value_b} ->
        for {timestamp, value} <- [{at_a, value_a}, {at_b, value_b}] do
          %{
            timestamp: timestamp,
            gateway_id: "gateway-example",
            agent_id: "poller-a",
            series_key: "#{uid}/#{index}/#{name}",
            device_id: uid,
            if_index: index,
            metric_type: "snmp",
            metric_name: name,
            counter_width: width,
            value: value
          }
        end
      end)

    Repo.insert_all("timeseries_metrics", rows, prefix: "platform")

    keys = Enum.map([1, 2, 3, 4], &{uid, &1})
    pps = Metrics.load_packet_pps(keys)

    assert pps == %{{uid, 1} => %{in: 100}, {uid, 4} => %{in: 50}}
  end

  test "topology uses the latest per-producer counter interval, not cumulative totals" do
    uid = "sr:rate-#{Ecto.UUID.generate()}"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    previous = DateTime.add(now, -30, :second)
    older = DateTime.add(now, -60, :second)

    samples = [
      {7, "ifOutUcastPkts", "poller-a", older, 100.0},
      {7, "ifOutUcastPkts", "poller-a", previous, 1000.0},
      {7, "ifOutUcastPkts", "poller-a", now, 1120.0},
      {7, "ifOutUcastPkts", "poller-b", now, 900_000.0},
      {7, "ifHCInOctets", "poller-a", previous, 10_000.0},
      {7, "ifHCInOctets", "poller-a", now, 16_000.0},
      # Reset: the previous value no longer fits a 32-bit counter, so it cannot be a wrap.
      {8, "ifOutUcastPkts", "poller-a", previous, 9_000_000_000.0},
      {8, "ifOutUcastPkts", "poller-a", now, 5.0},
      {9, "ifOutUcastPkts", "poller-a", now, 500.0}
    ]

    rows =
      Enum.map(samples, fn {index, name, agent, timestamp, value} ->
        %{
          timestamp: timestamp,
          gateway_id: "gateway-example",
          agent_id: agent,
          series_key: "#{uid}/#{index}/#{name}/#{agent}",
          device_id: uid,
          if_index: index,
          metric_type: "snmp",
          metric_name: name,
          value: value
        }
      end)

    Repo.insert_all("timeseries_metrics", rows, prefix: "platform")

    keys = Enum.map([7, 8, 9], &{uid, &1})
    assert Metrics.load_packet_pps(keys) == %{{uid, 7} => %{out: 4}}
    assert Metrics.load_octet_bps(keys) == %{{uid, 7} => %{in: 1600}}
  end
end
