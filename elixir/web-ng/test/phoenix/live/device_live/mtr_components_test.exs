defmodule ServiceRadarWebNGWeb.DeviceLive.MtrComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.MtrComponents

  @moduletag :db_free

  test "tab summary weights destination loss and RTT independently of missing RTT observations" do
    html =
      render_component(&MtrComponents.mtr_tab_content/1,
        device_uid: "sr:router-1",
        traces: [
          %{
            "id" => "older-unreached",
            "time" => ~U[2026-08-30 11:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => false,
            "total_hops" => 9,
            "protocol" => "icmp"
          }
        ],
        recent_traces: [
          %{
            "id" => "newer-reached-fast",
            "time" => ~U[2026-08-30 12:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 10,
            "destination_received" => 5,
            "destination_avg_us" => 10_000
          },
          %{
            "id" => "newer-reached-slow",
            "time" => ~U[2026-08-30 11:59:30Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 4,
            "protocol" => "icmp",
            "destination_sent" => 4,
            "destination_received" => 1,
            "destination_avg_us" => 50_000
          },
          %{
            "id" => "newer-reached-without-rtt",
            "time" => ~U[2026-08-30 11:59:15Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 5,
            "protocol" => "icmp",
            "destination_sent" => 6,
            "destination_received" => 6,
            "destination_avg_us" => nil
          },
          %{
            "id" => "newer-unreached",
            "time" => ~U[2026-08-30 11:59:00Z],
            "target" => "198.51.100.10",
            "target_reached" => false,
            "total_hops" => 7,
            "protocol" => "icmp"
          }
        ],
        pending_jobs: [],
        trends: %{hops: [], latency: []},
        total_count: 51,
        coverage: %{trace_count: 51, earliest_time: nil, latest_time: nil},
        retention_status: %{configured_days: 30, status: :ok, tables: %{}},
        page: 2,
        page_size: 50
      )

    assert html =~ ~s(id="device-mtr-reachability")
    assert html =~ ~s(id="device-mtr-destination-latency")
    assert html =~ ~s(id="device-mtr-destination-loss")
    assert html =~ ~s(id="device-mtr-recent-samples")
    assert html =~ "75.0%"
    assert html =~ "16.7ms"
    assert html =~ "40.0%"
    assert html =~ "Endpoint Samples"
    assert html =~ ">3<"
    assert html =~ "destination observations"
  end

  test "tab summary renders destination latency unavailable when no observation has RTT" do
    html =
      render_component(&MtrComponents.mtr_tab_content/1,
        device_uid: "sr:router-1",
        recent_traces: [
          %{
            "id" => "reached-without-rtt",
            "time" => ~U[2026-08-30 12:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 5,
            "destination_received" => 5,
            "destination_avg_us" => nil
          }
        ],
        pending_jobs: [],
        trends: %{hops: [], latency: []}
      )

    assert html =~ ~r/id="device-mtr-destination-latency"[^>]*>.*?>\s*.*?>\s*-\s*</s
    assert html =~ "0.0%"
    assert html =~ "Endpoint Samples"
    assert html =~ ">1<"
  end

  test "tab summary excludes replies from zero-attempt rows when accumulating destination loss" do
    html =
      render_component(&MtrComponents.mtr_tab_content/1,
        device_uid: "sr:router-1",
        recent_traces: [
          %{
            "id" => "valid-destination",
            "time" => ~U[2026-08-30 12:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 10,
            "destination_received" => 5,
            "destination_avg_us" => 10_000
          },
          %{
            "id" => "malformed-zero-attempts",
            "time" => ~U[2026-08-30 11:59:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 0,
            "destination_received" => 100,
            "destination_avg_us" => 20_000
          }
        ],
        pending_jobs: [],
        trends: %{hops: [], latency: []}
      )

    assert html =~
             ~r/id="device-mtr-destination-loss"[^>]*>.*?<div[^>]*>\s*50\.0%\s*<\/div>/s
  end

  test "tab summary renders a measured zero destination RTT as zero milliseconds" do
    html =
      render_component(&MtrComponents.mtr_tab_content/1,
        device_uid: "sr:router-1",
        recent_traces: [
          %{
            "id" => "zero-rtt",
            "time" => ~U[2026-08-30 12:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 5,
            "destination_received" => 5,
            "destination_avg_us" => 0
          }
        ],
        pending_jobs: [],
        trends: %{hops: [], latency: []}
      )

    assert html =~ ~r/id="device-mtr-destination-latency"[^>]*>.*?0\.0ms/s
  end

  test "trace modal reports destination loss independently from lossy intermediate hops" do
    html =
      render_component(&MtrComponents.mtr_trace_modal/1,
        show: true,
        trace: %{
          "target" => "198.51.100.10",
          "agent_id" => "agent-1",
          "protocol" => "icmp",
          "time" => ~U[2026-08-30 12:00:00Z],
          "target_reached" => true,
          "total_hops" => 2
        },
        hops: [
          %{
            "hop_number" => 1,
            "addr" => "192.0.2.1",
            "sent" => 5,
            "received" => 0,
            "loss_pct" => 100.0,
            "avg_us" => 2_000
          },
          %{
            "hop_number" => 2,
            "addr" => "198.51.100.10",
            "sent" => 5,
            "received" => 5,
            "loss_pct" => 0.0,
            "avg_us" => 10_000
          }
        ]
      )

    assert html =~ "Destination Loss"
    assert html =~ "0.0%"
    assert html =~ "Max Hop Loss"
    assert html =~ "100.0%"
    assert html =~ "Peak Hop Avg RTT"
  end

  test "trace modal selects the newest terminal duplicate by hop time and id" do
    html =
      render_component(&MtrComponents.mtr_trace_modal/1,
        show: true,
        trace: %{
          "target" => "198.51.100.10",
          "agent_id" => "agent-1",
          "protocol" => "icmp",
          "time" => ~U[2026-08-30 12:00:00Z],
          "target_reached" => true,
          "total_hops" => 2
        },
        hops: [
          %{
            "id" => "00000000-0000-0000-0000-000000000001",
            "time" => ~U[2026-08-30 12:00:01Z],
            "hop_number" => 2,
            "addr" => "newer-low-id.example",
            "sent" => 10,
            "received" => 0,
            "loss_pct" => 100.0,
            "avg_us" => 20_000
          },
          %{
            "id" => "ffffffff-ffff-ffff-ffff-ffffffffffff",
            "time" => ~U[2026-08-30 12:00:00Z],
            "hop_number" => 2,
            "addr" => "older-high-id.example",
            "sent" => 10,
            "received" => 0,
            "loss_pct" => 100.0,
            "avg_us" => 30_000
          },
          %{
            "id" => "00000000-0000-0000-0000-000000000002",
            "time" => ~U[2026-08-30 12:00:01Z],
            "hop_number" => 2,
            "addr" => "newer-high-id.example",
            "sent" => 10,
            "received" => 10,
            "loss_pct" => 0.0,
            "avg_us" => 10_000
          }
        ]
      )

    assert html =~ ~r/Destination Loss<\/div>\s*<div[^>]*>\s*0\.0%/s
    assert html =~ "newer-low-id.example"
    assert html =~ "older-high-id.example"
    assert html =~ "newer-high-id.example"
  end

  test "trace modal renders unavailable destination loss as a dash" do
    html =
      render_component(&MtrComponents.mtr_trace_modal/1,
        show: true,
        trace: %{
          "target" => "198.51.100.10",
          "agent_id" => "agent-1",
          "protocol" => "icmp",
          "time" => ~U[2026-08-30 12:00:00Z],
          "target_reached" => false,
          "total_hops" => 2
        },
        hops: [
          %{
            "hop_number" => 1,
            "addr" => "192.0.2.1",
            "sent" => 5,
            "received" => 0,
            "loss_pct" => 100.0,
            "avg_us" => 2_000
          }
        ]
      )

    assert html =~ "Destination Loss"
    assert html =~ ~r/Destination Loss<\/div>\s*<div[^>]*>\s*-/s
  end
end
