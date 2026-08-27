defmodule ServiceRadar.Edge.PublisherLaneTest do
  @moduledoc """
  Two properties carry this module, and neither is visible from the lane list alone:

    * every deployment-active `{route_profile, traffic_class}` pair maps to exactly one publisher,
      so no lane publishes on another lane's connection by falling through; and
    * the WIRE cannot select the recovery publisher, because recovery is a route profile that
      comes from the control-plane grant, not a traffic class an agent can name.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.PublisherLane
  alias ServiceRadar.Edge.StreamRoute

  @durable :EDGE_RECORD_ROUTE_PROFILE_DURABLE_RECORDS_V1
  @recovery :EDGE_RECORD_ROUTE_PROFILE_RECOVERY_CONTROL_V1
  @bulk :EDGE_RECORD_TRAFFIC_CLASS_BULK
  @interactive :EDGE_RECORD_TRAFFIC_CLASS_INTERACTIVE

  describe "the lane set is closed" do
    test "exactly three lanes, in a stable order" do
      assert PublisherLane.lanes() === [:bulk, :interactive, :recovery]
    end

    test "each lane has a DISTINCT connection name" do
      names = Enum.map(PublisherLane.lanes(), &PublisherLane.connection_name/1)

      # Two lanes sharing a connection is the exact failure this increment exists to prevent:
      # separate accounting over one socket is not separate capacity.
      assert length(Enum.uniq(names)) === length(names)
      assert Enum.all?(names, &is_atom/1)
    end

    test "connection_name/1 refuses anything that is not a lane" do
      # A per-scope or per-agent connection has to be UNREPRESENTABLE, not merely undocumented.
      for bad <- [:per_agent, {:scoped, "s"}, "bulk", nil, :EDGE_RECORD_TRAFFIC_CLASS_BULK] do
        assert_raise FunctionClauseError, fn -> PublisherLane.connection_name(bad) end
      end

      # NOT VACUOUS: the real lanes still resolve.
      for lane <- PublisherLane.lanes(), do: assert(is_atom(PublisherLane.connection_name(lane)))
    end
  end

  describe "every active lane maps to exactly one publisher" do
    test "the four deployment-active pairs map as specified" do
      assert PublisherLane.for_lane(@durable, @bulk) === {:ok, :bulk}
      assert PublisherLane.for_lane(@durable, @interactive) === {:ok, :interactive}
      # BOTH recovery pairs collapse: recovery resolves to one singular unpartitioned stream
      # regardless of class, so a second publisher would buy no isolation.
      assert PublisherLane.for_lane(@recovery, @bulk) === {:ok, :recovery}
      assert PublisherLane.for_lane(@recovery, @interactive) === {:ok, :recovery}
    end

    test "StreamRoute's active lanes are covered EXHAUSTIVELY" do
      active = StreamRoute.active_lanes()

      # Derived, not restated: a lane added to StreamRoute without a publisher must fail here
      # rather than silently publish on whichever connection a fallback clause chose.
      assignments = PublisherLane.active_assignments()

      assert length(assignments) === length(active)
      assert Enum.map(assignments, &elem(&1, 0)) === active

      for {_pair, lane} <- assignments do
        assert lane in PublisherLane.lanes()
      end
    end

    test "an unroutable pair is REFUSED, never defaulted onto a lane" do
      # A fallback lane would put unroutable traffic on a real publisher's credits.
      assert PublisherLane.for_lane(:EDGE_RECORD_ROUTE_PROFILE_CONTINUOUS_V1, @bulk) ===
               {:error, :unroutable_lane}

      assert PublisherLane.for_lane(@durable, :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED) ===
               {:error, :unroutable_lane}

      assert PublisherLane.for_lane(nil, nil) === {:error, :unroutable_lane}
      assert PublisherLane.for_lane(@durable, :made_up) === {:error, :unroutable_lane}
    end
  end

  describe "the wire cannot select the recovery publisher" do
    test "no traffic class alone reaches :recovery" do
      # The wire enum is UNSPECIFIED | BULK | INTERACTIVE -- there is no recovery member. Recovery
      # is reachable only through the route profile, which comes from the effective control-plane
      # grant rather than the frame, so an agent cannot ask for recovery capacity.
      wire_classes = [@bulk, @interactive, :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED]

      for class <- wire_classes do
        refute PublisherLane.for_lane(@durable, class) === {:ok, :recovery}
      end

      # NOT VACUOUS: the same classes DO reach recovery once the route profile says so, so the
      # refutation above is about the profile and not about these classes being inert.
      assert PublisherLane.for_lane(@recovery, @bulk) === {:ok, :recovery}
      assert PublisherLane.for_lane(@recovery, @interactive) === {:ok, :recovery}
    end

    test "the generated enum still has no recovery member" do
      # If a recovery traffic class is ever added to the ABI, the reasoning above stops holding
      # and this test is where that shows up.
      members = Map.keys(Serviceradar.Edge.V1.EdgeRecordTrafficClass.mapping())

      assert :EDGE_RECORD_TRAFFIC_CLASS_UNSPECIFIED in members
      refute Enum.any?(members, &(&1 |> Atom.to_string() |> String.contains?("RECOVERY")))
    end
  end
end
