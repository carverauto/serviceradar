defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepthTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepth

  @moduletag :db_free

  defp hop(number, received, addr \\ nil),
    do: %{"hop_number" => number, "sent" => 3, "received" => received, "addr" => addr}

  defp unreached(last, probed),
    do: %{"target_reached" => false, "last_responding_hop" => last, "probed_hops" => probed}

  describe "depth_summary/1 and hop_count_label/1" do
    test "a reached trace is described by its path length" do
      trace = %{"target_reached" => true, "total_hops" => 7, "last_responding_hop" => 7, "probed_hops" => 8}

      assert MtrDepth.depth_summary(trace) == "Reached in 7 hops"
      assert MtrDepth.hop_count_label(trace) == "7"
    end

    test "an unreached trace reports the last answer and the probed depth" do
      trace = %{"target_reached" => false, "total_hops" => 12, "last_responding_hop" => 7, "probed_hops" => 12}

      assert MtrDepth.depth_summary(trace) == "No reply past hop 7 (12 probed)"
      assert MtrDepth.hop_count_label(trace) == "7/12"
    end

    test "a trace with no replies at all says so" do
      trace = %{"target_reached" => false, "total_hops" => 4, "last_responding_hop" => 0, "probed_hops" => 4}

      assert MtrDepth.depth_summary(trace) == "No replies (4 probed)"
    end

    test "an older row without depth columns derives them from its hops" do
      trace = %{
        "target_reached" => false,
        "total_hops" => 5,
        "hops" => [hop(1, 3, "192.0.2.1"), hop(2, 3, "192.0.2.2"), hop(3, 0), hop(4, 0), hop(5, 0)]
      }

      assert MtrDepth.depth_summary(trace) == "No reply past hop 2 (5 probed)"
      assert MtrDepth.hop_count_label(trace) == "2/5"
    end

    test "an older list row with neither depth columns nor hops keeps its recorded count" do
      trace = %{"target_reached" => false, "total_hops" => 16}

      assert MtrDepth.hop_count_label(trace) == "16"
      assert MtrDepth.depth_summary(trace) == "Not reached (16 hops recorded)"
    end
  end

  describe "incomplete?/1" do
    defp cut_off_hops(deepest_reply) do
      [
        hop(1, 3, "192.0.2.1"),
        hop(2, 3, "192.0.2.2"),
        Map.merge(hop(3, 3, "198.51.100.3"), deepest_reply)
      ]
    end

    test "a trace cut off while its deepest hop still answered is incomplete, not unreachable" do
      trace = Map.put(unreached(3, 3), "hops", cut_off_hops(%{"reply_time_exceeded" => 3}))

      assert MtrDepth.incomplete?(trace)
      assert MtrDepth.depth_summary(trace) == "Stopped at hop 3 while hops were still answering"
      assert Helpers.trace_status_label(trace) == "Incomplete"
      assert Helpers.trace_status_variant(trace) == "warning"
    end

    test "an older row derives the cut-off from its hops" do
      trace = %{
        "target_reached" => false,
        "total_hops" => 3,
        "hops" => [hop(1, 3, "192.0.2.1"), hop(2, 0), hop(3, 2, "198.51.100.3")]
      }

      assert MtrDepth.incomplete?(trace)
    end

    test "a deepest hop answering Destination Unreachable is a blocked path, not a cut-off" do
      hops = cut_off_hops(%{"reply_unreachable" => 3, "unreachable_code" => 13})
      trace = Map.put(unreached(3, 3), "hops", hops)

      refute MtrDepth.incomplete?(trace)
      assert Helpers.trace_status_label(trace) == "Unreachable"
      assert Helpers.trace_status_variant(trace) == "error"
    end

    test "a trace without its hops is never incomplete" do
      trace = unreached(16, 16)

      refute MtrDepth.incomplete?(trace)
      assert Helpers.trace_status_label(trace) == "Unreachable"
    end

    test "a trace whose path went silent stays unreachable" do
      trace = Map.put(unreached(2, 3), "hops", [hop(1, 3, "192.0.2.1"), hop(2, 3, "192.0.2.2"), hop(3, 0)])

      refute MtrDepth.incomplete?(trace)
      assert Helpers.trace_status_label(trace) == "Unreachable"
    end

    test "reached traces, silent traces and rows without depth are never incomplete" do
      hops = cut_off_hops(%{"reply_time_exceeded" => 3})

      refute MtrDepth.incomplete?(%{Map.put(unreached(3, 3), "hops", hops) | "target_reached" => true})
      refute MtrDepth.incomplete?(unreached(0, 0))
      refute MtrDepth.incomplete?(%{"target_reached" => false, "total_hops" => 16})
    end
  end

  describe "collapse_trailing_loss/1" do
    test "folds the silent tail into one summary and keeps silent hops mid-path" do
      hops = [hop(1, 3, "192.0.2.1"), hop(2, 0), hop(3, 3, "192.0.2.3"), hop(4, 0), hop(5, 0), hop(6, 0)]

      {rows, tail} = MtrDepth.collapse_trailing_loss(hops)

      assert Enum.map(rows, & &1["hop_number"]) == [1, 2, 3]
      assert tail == %{from: 4, to: 6, count: 3}
    end

    test "leaves a single silent last hop and a fully answered path alone" do
      one_silent = [hop(1, 3, "192.0.2.1"), hop(2, 0)]
      answered = [hop(1, 3, "192.0.2.1"), hop(2, 3, "198.51.100.10")]

      assert MtrDepth.collapse_trailing_loss(one_silent) == {one_silent, nil}
      assert MtrDepth.collapse_trailing_loss(answered) == {answered, nil}
    end
  end

  describe "unreachable_kind/2" do
    test "names ICMPv4 and ICMPv6 codes from their own tables" do
      assert MtrDepth.unreachable_kind(13, 4) == "administratively prohibited"
      assert MtrDepth.unreachable_kind(3, 4) == "port unreachable"
      assert MtrDepth.unreachable_kind(1, 6) == "administratively prohibited"
      assert MtrDepth.unreachable_kind(4, 6) == "port unreachable"
      assert MtrDepth.unreachable_kind(42, 4) == "unreachable (code 42)"
    end

    test "is nil when the hop recorded no code" do
      assert MtrDepth.unreachable_kind(nil, 4) == nil
    end
  end

  describe "bar_depth/1 and the summary panel bar" do
    test "a reached trace draws its path length, an unreached one its last reply" do
      reached = %{"target_reached" => true, "total_hops" => 6, "last_responding_hop" => 6, "probed_hops" => 7}
      unreached = %{"target_reached" => false, "total_hops" => 30, "last_responding_hop" => 6, "probed_hops" => 30}

      assert MtrDepth.bar_depth(reached) == 6
      assert MtrDepth.bar_depth(unreached) == 6
    end

    test "a legacy row without depth columns or hops keeps its recorded length" do
      assert MtrDepth.bar_depth(%{"target_reached" => false, "total_hops" => 9}) == 9
    end

    test "an unreached TCP trace no longer stretches the bars of reached traces" do
      icmp = %{"target_reached" => true, "total_hops" => 8, "last_responding_hop" => 8, "probed_hops" => 8}
      tcp = %{"target_reached" => false, "total_hops" => 30, "last_responding_hop" => 4, "probed_hops" => 30}

      dashboard = Helpers.trace_history_dashboard([icmp, tcp], nil)

      assert dashboard.max_hops == 8
      assert Helpers.trace_hop_width(icmp, dashboard.max_hops) == "100.0%"
      assert Helpers.trace_hop_width(tcp, dashboard.max_hops) == "50.0%"
    end
  end

  describe "MtrData.build_trends/1 hop series" do
    test "plots the responding depth, so an unreached TCP trace does not spike the sparkline" do
      icmp = %{
        "time" => ~U[2026-08-30 12:00:00Z],
        "target_reached" => true,
        "total_hops" => 6,
        "last_responding_hop" => 6,
        "probed_hops" => 6
      }

      tcp = %{
        "time" => ~U[2026-08-30 11:59:00Z],
        "target_reached" => false,
        "total_hops" => 30,
        "last_responding_hop" => 4,
        "probed_hops" => 30
      }

      legacy = %{"time" => ~U[2026-08-30 11:58:00Z], "target_reached" => false, "total_hops" => 9}

      assert %{hops: hops} = MtrData.build_trends([icmp, tcp, legacy])

      assert hops == [
               {legacy["time"], 9},
               {tcp["time"], 4},
               {icmp["time"], 6}
             ]
    end
  end
end
