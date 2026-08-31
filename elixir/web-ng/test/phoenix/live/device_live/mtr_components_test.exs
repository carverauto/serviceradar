defmodule ServiceRadarWebNGWeb.DeviceLive.MtrComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DeviceLive.MtrComponents

  @moduletag :db_free

  test "tab summary uses recent attempts, probes, and replies instead of the paginated table" do
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
            "id" => "newer-reached",
            "time" => ~U[2026-08-30 12:00:00Z],
            "target" => "198.51.100.10",
            "target_reached" => true,
            "total_hops" => 3,
            "protocol" => "icmp",
            "destination_sent" => 10,
            "destination_received" => 4,
            "destination_avg_us" => 12_500
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
    assert html =~ "50.0%"
    assert html =~ "12.5ms"
    assert html =~ "60.0%"
    assert html =~ "Endpoint Samples"
    assert html =~ ">1<"
    assert html =~ "destination observations"
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
