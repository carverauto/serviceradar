defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrHandshakeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrHandshake

  @moduletag :db_free

  @measured %{
    "protocol" => "tcp",
    "tcp_handshake_attempts" => 3,
    "tcp_syn_sent" => 4,
    "tcp_synack_received" => 2,
    "tcp_rst_received" => 0,
    "tcp_syn_unanswered" => 1,
    "tcp_syn_drop_pct" => 33.333333333333336,
    "tcp_syn_retransmits" => 1,
    "tcp_answered_after_retx" => 0,
    "tcp_ack_mismatch" => 1,
    "tcp_synack_duplicates" => 2,
    "tcp_handshake_rtt_min_us" => 11_000,
    "tcp_handshake_rtt_avg_us" => 12_500,
    "tcp_handshake_rtt_max_us" => 14_000,
    "tcp_server_response_us" => 1_500
  }

  describe "handshake_panel/1" do
    test "shows every handshake figure with its definition" do
      html = render_component(&MtrHandshake.handshake_panel/1, trace: @measured)

      assert html =~ ~s(id="mtr-tcp-handshake")
      assert html =~ "33.3% (1/3)"
      assert html =~ "1 sent, 0 answered after"
      assert html =~ "1 mismatch, 2 dup"
      assert html =~ "11.0ms / 12.5ms / 14.0ms"
      assert html =~ "1.5ms"
      assert html =~ MtrHandshake.definition(:drop)
      assert html =~ MtrHandshake.definition(:server)
      refute html =~ "unavailable"
    end

    test "a TCP trace without handshake figures says the agent did not measure them" do
      html = render_component(&MtrHandshake.handshake_panel/1, trace: %{"protocol" => "tcp"})

      assert html =~ ~s(id="mtr-tcp-handshake-unavailable")
      refute html =~ "SYN drop"
    end

    test "a silent target shows a full drop and no RTT" do
      trace =
        Map.merge(@measured, %{
          "tcp_synack_received" => 0,
          "tcp_syn_unanswered" => 3,
          "tcp_syn_drop_pct" => 100.0,
          "tcp_handshake_rtt_min_us" => nil,
          "tcp_handshake_rtt_avg_us" => nil,
          "tcp_handshake_rtt_max_us" => nil,
          "tcp_server_response_us" => nil
        })

      html = render_component(&MtrHandshake.handshake_panel/1, trace: trace)

      assert html =~ "100.0% (3/3)"
      assert html =~ "- / - / -"
    end

    test "renders nothing for a non-TCP trace" do
      html = render_component(&MtrHandshake.handshake_panel/1, trace: %{"protocol" => "icmp"})

      refute html =~ "TCP Handshake"
    end
  end

  describe "reply_summary/1" do
    test "lists the reply kinds a hop returned" do
      assert MtrHandshake.reply_summary(%{"reply_time_exceeded" => 3, "reply_unreachable" => 0}) ==
               "3 TE"

      assert MtrHandshake.reply_summary(%{"reply_synack" => 2, "reply_rst" => 1}) == "2 SYN-ACK, 1 RST"
    end

    test "a hop without counters shows a dash" do
      assert MtrHandshake.reply_summary(%{"reply_time_exceeded" => nil}) == "-"
      assert MtrHandshake.reply_summary(%{"reply_time_exceeded" => 0, "reply_rst" => 0}) == "-"
    end
  end
end
