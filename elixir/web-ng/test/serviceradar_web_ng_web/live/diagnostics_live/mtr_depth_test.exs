defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepthTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DiagnosticsLive.Mtr.View.Helpers
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepth

  @moduletag :db_free

  defp hop(number, received, addr \\ nil),
    do: %{"hop_number" => number, "sent" => 3, "received" => received, "addr" => addr}

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
