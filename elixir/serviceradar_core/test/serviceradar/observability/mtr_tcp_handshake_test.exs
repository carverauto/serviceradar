defmodule ServiceRadar.Observability.MtrTcpHandshakeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrTcpHandshake

  @handshake %{
    "ttl" => 7,
    "attempts" => 3,
    "syn_sent" => 4,
    "synack_received" => 2,
    "rst_received" => 0,
    "unanswered" => 1,
    "syn_drop_pct" => 33.333333333333336,
    "syn_retransmits" => 1,
    "answered_after_retx" => 0,
    "ack_mismatch" => 1,
    "synack_duplicates" => 2,
    "rtt_min_us" => 11_000,
    "rtt_avg_us" => 12_500,
    "rtt_max_us" => 14_000,
    "server_response_us" => 1_500
  }

  describe "trace_fields/1" do
    test "maps every handshake counter to its column" do
      fields = MtrTcpHandshake.trace_fields(%{"protocol" => "tcp", "tcp_handshake" => @handshake})

      assert fields == %{
               tcp_handshake_ttl: 7,
               tcp_handshake_attempts: 3,
               tcp_syn_sent: 4,
               tcp_synack_received: 2,
               tcp_rst_received: 0,
               tcp_syn_unanswered: 1,
               tcp_syn_drop_pct: 33.333333333333336,
               tcp_syn_retransmits: 1,
               tcp_answered_after_retx: 0,
               tcp_ack_mismatch: 1,
               tcp_synack_duplicates: 2,
               tcp_handshake_rtt_min_us: 11_000,
               tcp_handshake_rtt_avg_us: 12_500,
               tcp_handshake_rtt_max_us: 14_000,
               tcp_server_response_us: 1_500
             }

      assert Enum.sort(Map.keys(fields)) == Enum.sort(MtrTcpHandshake.trace_columns())
    end

    test "a trace without a handshake phase stores nil, not zero" do
      for trace <- [%{"protocol" => "icmp"}, %{"protocol" => "tcp"}, %{"tcp_handshake" => nil}] do
        fields = MtrTcpHandshake.trace_fields(trace)

        assert Enum.all?(fields, fn {_column, value} -> is_nil(value) end)
        assert map_size(fields) == length(MtrTcpHandshake.trace_columns())
      end
    end

    test "a silent target keeps its zero counters but has no RTT or server estimate" do
      silent = %{
        "ttl" => 30,
        "attempts" => 3,
        "syn_sent" => 6,
        "synack_received" => 0,
        "rst_received" => 0,
        "unanswered" => 3,
        "syn_drop_pct" => 100,
        "syn_retransmits" => 3,
        "answered_after_retx" => 0,
        "ack_mismatch" => 0,
        "synack_duplicates" => 0
      }

      fields = MtrTcpHandshake.trace_fields(%{"tcp_handshake" => silent})

      assert fields.tcp_synack_received == 0
      assert fields.tcp_syn_unanswered == 3
      assert fields.tcp_syn_drop_pct == 100.0
      assert fields.tcp_handshake_rtt_avg_us == nil
      assert fields.tcp_server_response_us == nil
    end

    test "malformed values are not stored as figures" do
      fields =
        MtrTcpHandshake.trace_fields(%{
          "tcp_handshake" => Map.merge(@handshake, %{"syn_sent" => "4", "rtt_avg_us" => -1})
        })

      assert fields.tcp_syn_sent == 0
      assert fields.tcp_handshake_rtt_avg_us == nil
    end
  end

  describe "reply counters" do
    test "missing counters are zero when the agent reports counters" do
      hops = [
        %{"hop_number" => 1, "reply_time_exceeded" => 3},
        %{"hop_number" => 2, "reply_synack" => 2, "reply_rst" => 1}
      ]

      assert MtrTcpHandshake.reply_counters_reported?(hops)

      assert MtrTcpHandshake.hop_fields(Enum.at(hops, 1), true) == %{
               reply_time_exceeded: 0,
               reply_unreachable: 0,
               reply_synack: 2,
               reply_rst: 1
             }
    end

    test "an agent that does not report counters stores nil" do
      hops = [%{"hop_number" => 1, "sent" => 3, "received" => 3}]

      refute MtrTcpHandshake.reply_counters_reported?(hops)

      assert MtrTcpHandshake.hop_fields(hd(hops), false) == %{
               reply_time_exceeded: nil,
               reply_unreachable: nil,
               reply_synack: nil,
               reply_rst: nil
             }
    end
  end
end
