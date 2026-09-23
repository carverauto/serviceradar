defmodule ServiceRadar.Observability.MtrTraceDepthTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrTraceDepth

  defp hop(number, sent, received),
    do: %{"hop_number" => number, "sent" => sent, "received" => received}

  # A trace that never reached its target: replies stop after hop 3 while
  # probing continued to hop 6.
  defp unreached_hops,
    do: [hop(1, 3, 3), hop(2, 3, 3), hop(3, 3, 1), hop(4, 3, 0), hop(5, 3, 0), hop(6, 2, 0)]

  describe "trace from an agent that reports depth" do
    test "uses the reported figures, including a zero last responding hop" do
      trace = %{"probed_hops" => 16, "last_responding_hop" => 0}

      assert MtrTraceDepth.probed_hops(trace, unreached_hops()) == 16
      assert MtrTraceDepth.last_responding_hop(trace, unreached_hops()) == 0
    end
  end

  describe "trace from an agent that predates the depth fields" do
    test "derives probed depth and last responding hop from the hops" do
      assert MtrTraceDepth.probed_hops(%{}, unreached_hops()) == 6
      assert MtrTraceDepth.last_responding_hop(%{}, unreached_hops()) == 3
    end

    test "reports zero for a trace with no hops" do
      assert MtrTraceDepth.probed_hops(%{}, []) == 0
      assert MtrTraceDepth.last_responding_hop(%{}, nil) == 0
    end

    test "ignores malformed hop entries" do
      hops = [hop(1, 3, 3), %{"hop_number" => "2", "sent" => 3, "received" => 3}, :bogus]

      assert MtrTraceDepth.last_responding_hop(%{}, hops) == 1
    end
  end

  describe "tcp_port/1" do
    test "keeps the port of a TCP trace" do
      assert MtrTraceDepth.tcp_port(%{"protocol" => "tcp", "tcp_port" => 443}) == 443
    end

    test "is nil for other protocols and for out-of-range ports" do
      assert MtrTraceDepth.tcp_port(%{"protocol" => "icmp", "tcp_port" => 443}) == nil
      assert MtrTraceDepth.tcp_port(%{"protocol" => "tcp", "tcp_port" => 0}) == nil
      assert MtrTraceDepth.tcp_port(%{"protocol" => "tcp", "tcp_port" => 70_000}) == nil
      assert MtrTraceDepth.tcp_port(%{"protocol" => "tcp"}) == nil
    end
  end
end
