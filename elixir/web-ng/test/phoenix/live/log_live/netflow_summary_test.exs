defmodule ServiceRadarWebNGWeb.LogLive.NetflowSummaryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowSummary

  @moduletag :db_free

  test "one grouped query carries every card, and keeps the caller's filters" do
    query = NetflowSummary.query("in:flows time:last_1h src_ip:192.0.2.10")

    assert String.starts_with?(query, "in:flows time:last_1h src_ip:192.0.2.10 stats:")
    assert query =~ "count(*) as total"
    assert query =~ "sum(bytes_total) as total_bytes"
    assert query =~ "sum(packets_total) as total_packets"
    assert query =~ "by protocol_num"
    # A protocol number fits in a byte; a smaller limit could drop a row and
    # leave every total short.
    assert query =~ "limit:256"
  end

  test "totals are the sum of the protocol rows, split into tcp, udp and other" do
    rows = [
      %{"protocol_num" => 6, "total" => 16_560, "total_bytes" => 1_520_792_315.0, "total_packets" => 2_108_590.0},
      %{"protocol_num" => 17, "total" => 1_078, "total_bytes" => 28_700_986.0, "total_packets" => 137_733.0},
      %{"protocol_num" => 1, "total" => 40, "total_bytes" => 3_200.0, "total_packets" => 40.0},
      %{"protocol_num" => 47, "total" => 2, "total_bytes" => 500.0, "total_packets" => 2.0}
    ]

    summary = NetflowSummary.from_rows(rows, 3_600)

    assert summary.total == 17_680
    assert summary.tcp == 16_560
    assert summary.udp == 1_078
    assert summary.other == 42
    assert summary.total_bytes == 1_549_497_001
    assert summary.total_packets == 2_246_365
    assert summary.window_seconds == 3_600
  end

  test "rates use the selected window, not a fixed hour" do
    rows = [%{"protocol_num" => 6, "total" => 2, "total_bytes" => 10_800_000, "total_packets" => 86_400}]

    day = NetflowSummary.from_rows(rows, 86_400)
    assert day.avg_bps == 1_000.0
    assert day.avg_pps == 1.0

    hour = NetflowSummary.from_rows(rows, 3_600)
    assert hour.avg_bps == 24_000.0
    assert hour.avg_pps == 24.0
  end

  test "an empty window is zeros, and odd values do not raise" do
    assert %{total: 0, tcp: 0, udp: 0, other: 0, total_bytes: 0, avg_bps: avg_bps} =
             NetflowSummary.from_rows([], 3_600)

    assert avg_bps == 0.0

    rows = [%{"protocol_num" => "6", "total" => "3", "total_bytes" => nil, "total_packets" => "12.0"}]
    summary = NetflowSummary.from_rows(rows, 60)

    assert summary.total == 3
    assert summary.tcp == 3
    assert summary.total_bytes == 0
    assert summary.total_packets == 12
  end
end
