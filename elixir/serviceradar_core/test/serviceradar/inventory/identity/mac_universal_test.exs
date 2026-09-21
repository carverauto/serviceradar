defmodule ServiceRadar.Inventory.Identity.MacUniversalTest do
  @moduledoc """
  Unit coverage for the extracted hardware-identity grouping primitives
  (`universal_macs/1`, `distinct_hardware?/2`) shared by the ingest-time
  distinct-MAC veto (`BatchResolver`) and the armis-unmerge remediation, so
  un-merge detection provably cannot drift from prevention.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.InterfaceMacs
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

  # Regression: an all-zero ifPhysAddress was accepted as :strong identity, so
  # two unrelated devices that both reported one formed a two-device duplicate
  # component and were merged unattended by the scheduled reconciler. The
  # locally-administered check cannot catch it, which is the whole reason a
  # reserved-value list is needed -- the first assertion below pins that.
  describe "reserved MAC values are never identity" do
    test "an all-zero MAC is not locally administered, so the LAA guard alone misses it" do
      refute Mac.locally_administered_mac?("000000000000")
      refute Mac.locally_administered_mac?("FFFFFFFFFFFF")
    end

    test "reserved_mac_value?/1 recognizes the values that carry no identity" do
      assert Mac.reserved_mac_value?("000000000000")
      assert Mac.reserved_mac_value?("FFFFFFFFFFFF")
      refute Mac.reserved_mac_value?("00005E005301")
      refute Mac.reserved_mac_value?(nil)
    end

    test "normalize_mac/1 rejects reserved values in every separator form" do
      assert Mac.normalize_mac("00:00:00:00:00:00") == nil
      assert Mac.normalize_mac("000000000000") == nil
      assert Mac.normalize_mac("00-00-00-00-00-00") == nil
      assert Mac.normalize_mac("ff:ff:ff:ff:ff:ff") == nil
      assert Mac.normalize_mac("FFFFFFFFFFFF") == nil
    end

    test "normalize_mac/1 still accepts an ordinary MAC" do
      assert Mac.normalize_mac("00:00:5e:00:53:01") == "00005E005301"
    end

    test "normalize_mac_list/1 drops reserved values and keeps the rest" do
      assert Mac.normalize_mac_list("00:00:00:00:00:00 00:00:5e:00:53:01") == ["00005E005301"]
      assert Mac.normalize_mac_list("00:00:00:00:00:00,ff:ff:ff:ff:ff:ff") == []
    end

    test "universal_macs/1 does not surface a reserved value as hardware identity" do
      assert Mac.universal_macs(["00:00:00:00:00:00"]) == MapSet.new()
      assert Mac.universal_macs(["ff:ff:ff:ff:ff:ff"]) == MapSet.new()
    end

    # The second half of the fix: InterfaceMacs keeps its own looser normalizer
    # for SNMP shapes, and it must apply the same reserved-value rule or the
    # duplicate sweep can still join an all-zero interface MAC to another
    # device's identifier.
    test "InterfaceMacs.eligible/1 applies the same reserved-value rule" do
      assert InterfaceMacs.eligible(["00:00:00:00:00:00"]) == []
      assert InterfaceMacs.eligible(["ff:ff:ff:ff:ff:ff"]) == []
      assert InterfaceMacs.eligible(["00:00:5e:00:53:02"]) == ["00005E005302"]

      assert InterfaceMacs.eligible(["00:00:00:00:00:00", "00:00:5e:00:53:02"]) == [
               "00005E005302"
             ]
    end
  end
end
