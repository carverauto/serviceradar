defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.TelemetryMetricsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics
  alias ServiceRadar.Repo

  @moduletag :integration

  test "topology recovers bounded counter wraps and drops resets" do
    uid = "sr:wrap-#{Ecto.UUID.generate()}"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    previous = DateTime.shift(now, second: -10)
    half_second = DateTime.add(now, -500, :millisecond)
    modulus_32 = 4_294_967_296.0
    modulus_64 = 18_446_744_073_709_551_616.0
    ceiling = %{"max_counter_rate_per_second" => "1000000"}

    # {if_index, metric_name, counter_width, metadata, previous_at, previous_value, value}
    samples = [
      # 32-bit wrap: 100 packets after the wrap plus 900 before it, over 10s.
      {1, "ifInUcastPkts", 32, nil, previous, modulus_32 - 900.0, 100.0},
      # 32-bit decrease inside half a second: a wrap would imply over 2^32 packets/s.
      {2, "ifInUcastPkts", 32, nil, half_second, 3_000_000.0, 40.0},
      # 64-bit decrease with no producer ceiling: reset, never a 32-bit wrap.
      {3, "ifHCInUcastPkts", 64, nil, previous, 9_000.0, 5.0},
      # Unknown width, previous value fits in 32 bits: treated as a wrap.
      {4, "ifInUcastPkts", nil, nil, previous, modulus_32 - 400.0, 100.0},
      # 32-bit decrease whose wrap would exceed the producer ceiling: reset.
      {5, "ifInUcastPkts", 32, ceiling, previous, 9_000.0, 5.0},
      # 64-bit wrap accepted because the producer ceiling bounds the implied rate.
      {6, "ifHCInUcastPkts", 64, ceiling, previous, modulus_64 - 40_960.0, 40_960.0},
      # Negative value must not create a rate.
      {7, "ifInUcastPkts", 32, nil, previous, 100.0, -5.0},
      # Increase above the producer ceiling is neither a rate nor a wrap.
      {8, "ifInUcastPkts", 32, %{"max_counter_rate_per_second" => "1000"}, previous, 0.0,
       100_000_000.0}
    ]

    rows =
      Enum.flat_map(samples, fn {index, name, width, metadata, at, previous_value, value} ->
        for {timestamp, sample} <- [{at, previous_value}, {now, value}] do
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
            metadata: metadata,
            value: sample
          }
        end
      end)

    Repo.insert_all("timeseries_metrics", rows, prefix: "platform")

    keys = Enum.map(1..8, &{uid, &1})
    pps = Metrics.load_packet_pps(keys)

    assert pps == %{
             {uid, 1} => %{in: 100},
             {uid, 4} => %{in: 50},
             {uid, 6} => %{in: 8192}
           }
  end

  test "topology uses the latest per-producer counter interval, not cumulative totals" do
    uid = "sr:rate-#{Ecto.UUID.generate()}"
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)
    previous = DateTime.shift(now, second: -30)
    older = DateTime.shift(now, minute: -1)
    retired_previous = DateTime.shift(now, minute: -21)
    retired_latest = DateTime.shift(now, minute: -20)

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
      {9, "ifOutUcastPkts", "poller-a", now, 500.0},
      # A retired collector's higher rate must not override the active collector.
      {10, "ifOutUcastPkts", "poller-a", retired_previous, 0.0},
      {10, "ifOutUcastPkts", "poller-a", retired_latest, 600_000.0},
      {10, "ifOutUcastPkts", "poller-b", previous, 100.0},
      {10, "ifOutUcastPkts", "poller-b", now, 160.0},
      # The newest producer has no interval: do not reuse the retired rate.
      {11, "ifOutUcastPkts", "poller-a", retired_previous, 0.0},
      {11, "ifOutUcastPkts", "poller-a", retired_latest, 600_000.0},
      {11, "ifOutUcastPkts", "poller-b", now, 160.0},
      # A reset on the active producer must not revive the retired rate either.
      {12, "ifOutUcastPkts", "poller-a", retired_previous, 0.0},
      {12, "ifOutUcastPkts", "poller-a", retired_latest, 600_000.0},
      {12, "ifOutUcastPkts", "poller-b", previous, 9_000_000_000.0},
      {12, "ifOutUcastPkts", "poller-b", now, 5.0}
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

    keys = Enum.map(7..12, &{uid, &1})
    assert Metrics.load_packet_pps(keys) == %{{uid, 7} => %{out: 4}, {uid, 10} => %{out: 2}}
    assert Metrics.load_octet_bps(keys) == %{{uid, 7} => %{in: 1600}}
  end
end
