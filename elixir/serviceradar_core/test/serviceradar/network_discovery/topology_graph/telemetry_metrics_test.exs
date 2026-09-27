defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.TelemetryMetricsTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Telemetry.Metrics
  alias ServiceRadar.Repo

  @moduletag :integration

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
      {8, "ifOutUcastPkts", "poller-a", previous, 9000.0},
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
