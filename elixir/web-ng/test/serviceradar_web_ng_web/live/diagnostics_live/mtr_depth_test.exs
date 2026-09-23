defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDepthTest do
  use ExUnit.Case, async: true

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
end
