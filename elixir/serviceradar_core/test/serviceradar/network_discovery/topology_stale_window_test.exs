defmodule ServiceRadar.NetworkDiscovery.TopologyStaleWindowTest do
  @moduledoc """
  How long a projected topology edge stays asserted as current.

  A topology edge is a claim about how the network is wired *now*, and the only
  thing keeping it true is re-observation. So "is this stale?" means "has it
  survived several chances to be re-observed?" -- which depends on the discovery
  interval, not on a wall clock.

  A fixed window is wrong in both directions, and both directions are tested
  here: too short and healthy edges are deleted between runs and re-created on
  the next, flapping the map forever; too long and a dead link stands for dozens
  of intervals. The second is what left a deployment showing 14-day-old topology
  from a discovery job that had been deleted.
  """
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  @floor_minutes 180

  describe "parse_interval_minutes/1" do
    test "parses the units discovery intervals actually use" do
      assert Utils.parse_interval_minutes("15m") == 15
      assert Utils.parse_interval_minutes("2h") == 120
      assert Utils.parse_interval_minutes("1d") == 1440
      assert Utils.parse_interval_minutes("30") == 30
    end

    test "rounds a sub-minute interval up rather than to zero" do
      # A zero window would make every edge instantly stale.
      assert Utils.parse_interval_minutes("30s") == 1
      assert Utils.parse_interval_minutes("90s") == 2
    end

    test "tolerates whitespace and case" do
      assert Utils.parse_interval_minutes(" 2H ") == 120
    end

    test "unparseable input is nil, not a guess" do
      assert Utils.parse_interval_minutes("soon") == nil
      assert Utils.parse_interval_minutes("") == nil
      assert Utils.parse_interval_minutes("0h") == nil
      assert Utils.parse_interval_minutes(nil) == nil
      assert Utils.parse_interval_minutes(120) == nil
    end
  end

  describe "derive_stale_minutes/2" do
    test "a slow job is never pruned faster than it can refresh" do
      # The flapping case: a 6-hour job against the 180-minute floor would have
      # every healthy edge deleted between runs.
      assert Utils.derive_stale_minutes(["6h"], 3) == 6 * 60 * 3
    end

    test "the slowest enabled interval wins" do
      # Edges record no job, so pruning on anything faster would delete links the
      # slowest job has not yet had a chance to refresh.
      assert Utils.derive_stale_minutes(["5m", "2h", "15m"], 3) == 2 * 60 * 3
    end

    test "a fast job is floored, not pruned aggressively" do
      # 3 x 5m = 15m would delete edges faster than consumers read them.
      assert Utils.derive_stale_minutes(["5m"], 3) == @floor_minutes
    end

    test "no intervals falls back to the floor rather than deriving from nothing" do
      assert Utils.derive_stale_minutes([], 3) == @floor_minutes
      assert Utils.derive_stale_minutes(["soon", ""], 3) == @floor_minutes
    end

    test "the multiplier is honoured" do
      assert Utils.derive_stale_minutes(["2h"], 5) == 2 * 60 * 5
      assert Utils.derive_stale_minutes(["10h"], 1) == 600
    end

    test "the window is always a multiple of a real interval, so an hourly job survives" do
      # The motivating deployment: hourly discovery, edges must not be pruned
      # while the job is healthy.
      window = Utils.derive_stale_minutes(["1h"], 3)

      assert window >= 60, "an hourly job would be pruned before it could refresh"
      assert window == @floor_minutes
    end
  end

  describe "the pruning switch" do
    test "is on unless explicitly disabled" do
      # Shipped off, which is why a deployment sat on 14-day-old topology with no
      # way for an operator to fix it short of a manual purge.
      assert Utils.stale_interval_multiplier() > 0
    end
  end
end
