defmodule ServiceRadarWebNGWeb.DashboardLive.MtrMetricsTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNGWeb.DashboardLive.Data

  test "dashboard MTR metrics use reached terminal destinations with counter and reply weighting" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("dashboard-mtr-a", timestamp,
      target_reached: true,
      hops: [
        {"10.0.0.1", 900_000, 10, 1},
        {"198.51.100.10", 10_000, 10, 10}
      ]
    )

    insert_mtr_trace!("dashboard-mtr-b", timestamp,
      target_reached: true,
      hops: [
        {"10.0.0.2", 5_000, 20, 20},
        {"198.51.100.20", 40_000, 20, 5}
      ]
    )

    insert_mtr_trace!("dashboard-mtr-c", timestamp,
      target_reached: false,
      hops: [
        {"10.0.0.3", 800_000, 30, 30},
        {nil, 0, 30, 0}
      ]
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")
    %{sparklines: sparklines} = Data.load_sparklines("last_1h")

    assert summary.path_count == 3
    assert summary.endpoint_sample_count == 2
    assert summary.loss_sample_count == 2
    assert summary.latency_sample_count == 2
    assert_in_delta summary.avg_loss_pct, 50.0, 1.0e-10
    assert_in_delta summary.avg_latency_ms, 20.0, 1.0e-10
    assert summary.degraded_count == 2

    assert [latency_ms] = sparklines.latency
    assert [loss_pct] = sparklines.packet_loss
    assert_in_delta latency_ms, 20.0, 1.0e-10
    assert_in_delta loss_pct, 50.0, 1.0e-10
  end

  test "dashboard keeps path-only MTR data active while withholding endpoint cards" do
    dashboard =
      Data.derive(%{
        mtr_timeseries: %{
          path_count: 1,
          endpoint_sample_count: 0,
          loss_sample_count: 0,
          latency_sample_count: 0,
          avg_loss_pct: nil,
          avg_latency_ms: nil,
          degraded_count: 1
        },
        loaded: %{mtr: true}
      })

    assert dashboard.module_states.mtr == :active

    metrics = Map.new(dashboard.observability_metrics, &{&1.label, &1})

    assert %{
             available: false,
             value: "No endpoint sample",
             scale: "",
             sparkline: [],
             axis_min: "",
             axis_mid: "",
             axis_max: ""
           } =
             metrics["Destination Latency"]

    assert %{
             available: false,
             value: "No endpoint sample",
             scale: "",
             sparkline: [],
             axis_min: "",
             axis_mid: "",
             axis_max: ""
           } =
             metrics["Destination Loss"]
  end

  test "missing destination RTT leaves latency unavailable while loss remains available" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("dashboard-mtr-missing-rtt", timestamp,
      target_reached: true,
      hops: [{"198.51.100.50", nil, 10, 10}]
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")
    %{sparklines: sparklines} = Data.load_sparklines("last_1h")

    assert summary.endpoint_sample_count == 1
    assert summary.loss_sample_count == 1
    assert summary.latency_sample_count == 0
    assert summary.avg_latency_ms == nil
    assert_in_delta summary.avg_loss_pct, 0.0, 1.0e-10
    assert sparklines.latency == []
    assert sparklines.packet_loss == [0.0]

    dashboard =
      Data.derive(%{
        mtr_timeseries: summary,
        sparklines: sparklines,
        loaded: %{mtr: true}
      })

    metrics = Map.new(dashboard.observability_metrics, &{&1.label, &1})

    assert %{
             available: false,
             value: "No endpoint sample",
             scale: "",
             sparkline: [],
             axis_min: "",
             axis_mid: "",
             axis_max: ""
           } = metrics["Destination Latency"]

    assert %{available: true, value: "0.0", scale: "%", sparkline: [loss_pct]} =
             metrics["Destination Loss"]

    assert_in_delta loss_pct, 0.0, 1.0e-10
  end

  test "dashboard excludes zero-probe destinations from loss weighting" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("dashboard-mtr-probed", timestamp,
      target_reached: true,
      hops: [{"198.51.100.30", 10_000, 10, 5}]
    )

    insert_mtr_trace!("dashboard-mtr-unprobed", timestamp,
      target_reached: true,
      hops: [{"198.51.100.31", 10_000, 0, 0}]
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")
    %{sparklines: sparklines} = Data.load_sparklines("last_1h")

    assert summary.endpoint_sample_count == 2
    assert_in_delta summary.avg_loss_pct, 50.0, 1.0e-10
    assert [loss_pct] = sparklines.packet_loss
    assert_in_delta loss_pct, 50.0, 1.0e-10
  end

  test "zero-probe destination leaves metrics unavailable despite an endpoint observation" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("dashboard-mtr-zero-probe", timestamp,
      target_reached: true,
      hops: [{"198.51.100.60", 25_000, 0, 0}]
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")
    %{sparklines: sparklines} = Data.load_sparklines("last_1h")

    assert summary.endpoint_sample_count == 1
    assert summary.loss_sample_count == 0
    assert summary.latency_sample_count == 0
    assert summary.avg_loss_pct == nil
    assert summary.avg_latency_ms == nil
    assert sparklines.packet_loss == []
    assert sparklines.latency == []

    dashboard =
      Data.derive(%{
        mtr_timeseries: summary,
        sparklines: sparklines,
        loaded: %{mtr: true}
      })

    metrics = Map.new(dashboard.observability_metrics, &{&1.label, &1})

    assert %{available: false, value: "No endpoint sample", scale: "", sparkline: []} =
             metrics["Destination Loss"]

    assert %{available: false, value: "No endpoint sample", scale: "", sparkline: []} =
             metrics["Destination Latency"]
  end

  test "zero destination RTT remains a latency observation" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    insert_mtr_trace!("dashboard-mtr-zero-rtt", timestamp,
      target_reached: true,
      hops: [{"198.51.100.70", 0, 5, 5}]
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")

    assert summary.endpoint_sample_count == 1
    assert summary.loss_sample_count == 1
    assert summary.latency_sample_count == 1
    assert_in_delta summary.avg_loss_pct, 0.0, 1.0e-10
    assert_in_delta summary.avg_latency_ms, 0.0, 1.0e-10

    dashboard = Data.derive(%{mtr_timeseries: summary, loaded: %{mtr: true}})
    metrics = Map.new(dashboard.observability_metrics, &{&1.label, &1})

    assert %{available: true, value: "0.0", scale: "ms"} = metrics["Destination Latency"]
    assert %{available: true, value: "0.0", scale: "%"} = metrics["Destination Loss"]
  end

  test "dashboard uses one deterministic terminal observation per trace" do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    trace_id =
      insert_mtr_trace!("dashboard-mtr-duplicate-terminal", timestamp,
        target_reached: true,
        hops: [{"198.51.100.40", 900_000, 10, 10}]
      )

    insert_duplicate_terminal_hop!(
      trace_id,
      DateTime.add(timestamp, 1, :second),
      {"198.51.100.40", 20_000, 20, 10}
    )

    %{mtr_timeseries: summary} = Data.load_mtr("last_1h")
    %{sparklines: sparklines} = Data.load_sparklines("last_1h")

    assert summary.path_count == 1
    assert summary.endpoint_sample_count == 1
    assert summary.degraded_count == 1
    assert_in_delta summary.avg_loss_pct, 50.0, 1.0e-10
    assert_in_delta summary.avg_latency_ms, 20.0, 1.0e-10
    assert [latency_ms] = sparklines.latency
    assert [loss_pct] = sparklines.packet_loss
    assert_in_delta latency_ms, 20.0, 1.0e-10
    assert_in_delta loss_pct, 50.0, 1.0e-10
  end

  defp insert_mtr_trace!(agent_id, timestamp, opts) do
    id = Ecto.UUID.generate()
    db_id = dump_uuid!(id)
    hops = Keyword.fetch!(opts, :hops)

    ServiceRadar.Repo.insert_all("mtr_traces", [
      %{
        id: db_id,
        time: timestamp,
        agent_id: agent_id,
        gateway_id: "gateway-test",
        check_id: "check-#{id}",
        check_name: "MTR dashboard metrics",
        device_id: nil,
        target: "198.51.100.254",
        target_ip: "198.51.100.254",
        target_reached: Keyword.fetch!(opts, :target_reached),
        total_hops: length(hops),
        protocol: "icmp",
        ip_version: 4,
        packet_size: 64,
        partition: "default",
        error: nil,
        created_at: timestamp
      }
    ])

    ServiceRadar.Repo.insert_all(
      "mtr_hops",
      hops
      |> Enum.with_index(1)
      |> Enum.map(fn {{addr, avg_us, sent, received}, hop_number} ->
        mtr_hop_row(db_id, timestamp, hop_number, {addr, avg_us, sent, received})
      end)
    )

    id
  end

  defp insert_duplicate_terminal_hop!(trace_id, timestamp, {addr, avg_us, sent, received}) do
    ServiceRadar.Repo.insert_all("mtr_hops", [
      mtr_hop_row(dump_uuid!(trace_id), timestamp, 1, {addr, avg_us, sent, received})
    ])
  end

  defp mtr_hop_row(trace_id, timestamp, hop_number, {addr, avg_us, sent, received}) do
    %{
      id: dump_uuid!(Ecto.UUID.generate()),
      time: timestamp,
      trace_id: trace_id,
      hop_number: hop_number,
      addr: addr,
      hostname: nil,
      ecmp_addrs: [],
      asn: nil,
      asn_org: nil,
      mpls_labels: %{},
      sent: sent,
      received: received,
      loss_pct: if(sent > 0, do: 100.0 * (sent - received) / sent, else: 0.0),
      last_us: avg_us,
      avg_us: avg_us,
      min_us: avg_us,
      max_us: avg_us,
      stddev_us: 0,
      jitter_us: 0,
      jitter_worst_us: 0,
      jitter_interarrival_us: 0,
      created_at: timestamp
    }
  end

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> uuid
    end
  end
end
