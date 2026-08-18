defmodule ServiceRadar.Inventory.Identity.MacUniversalTest do
  @moduledoc """
  Unit coverage for the extracted hardware-identity grouping primitives
  (`universal_macs/1`, `distinct_hardware?/2`) shared by the ingest-time
  distinct-MAC veto (`BatchResolver`) and the armis-unmerge remediation, so
  un-merge detection provably cannot drift from prevention.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Mac

  describe "universal_macs/1" do
    test "keeps universally-administered atomic MACs" do
      assert Mac.universal_macs(["001AA0B94040"]) == MapSet.new(["001AA0B94040"])
    end

    test "drops locally-administered MACs (2nd hex char has the 0x02 bit)" do
      assert Mac.universal_macs(["02EA1432D278", "F692BF75C722"]) == MapSet.new()
    end

    test "normalizes comma blobs to atomic MACs before filtering" do
      assert Mac.universal_macs(["001AA0B94040,02EA1432D278,00:14:22:F4:2A:2A"]) ==
               MapSet.new(["001AA0B94040", "001422F42A2A"])
    end

    test "accepts a bare string, drops malformed values, handles nil" do
      assert Mac.universal_macs("001AA0B94040") == MapSet.new(["001AA0B94040"])
      assert Mac.universal_macs(["not-a-mac", "00AA"]) == MapSet.new()
      assert Mac.universal_macs(nil) == MapSet.new()
    end
  end

  describe "distinct_hardware?/2" do
    test "fires only when both sides are non-empty AND disjoint" do
      a = MapSet.new(["001AA0B94040"])
      b = MapSet.new(["001422F42A2A"])
      assert Mac.distinct_hardware?(a, b)
    end

    test "a shared MAC is never distinct hardware" do
      a = MapSet.new(["001AA0B94040", "001422F42A2A"])
      b = MapSet.new(["001422F42A2A"])
      refute Mac.distinct_hardware?(a, b)
    end

    test "an empty side is never distinct hardware" do
      refute Mac.distinct_hardware?(MapSet.new(), MapSet.new(["001AA0B94040"]))
      refute Mac.distinct_hardware?(MapSet.new(["001AA0B94040"]), MapSet.new())
      refute Mac.distinct_hardware?(MapSet.new(), MapSet.new())
    end
  end

  describe "hardware_mac_sibling/1" do
    test "flips IEEE bit 1 of the first octet" do
      assert Mac.hardware_mac_sibling("F492BF75C721") == "F692BF75C721"
      assert Mac.hardware_mac_sibling("f6:92:bf:75:c7:21") == "F492BF75C721"
      assert Mac.hardware_mac_sibling("not-a-mac") == nil
    end
  end

  describe "lookup_macs_with_siblings/1" do
    test "adds the UAA/LAA pair for lookup without dropping the observed MAC" do
      assert Mac.lookup_macs_with_siblings(["f6:92:bf:75:c7:21"]) == [
               "F692BF75C721",
               "F492BF75C721"
             ]
    end
  end
end
