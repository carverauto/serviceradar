defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.UtilsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Utils

  describe "normalize_interface_label/1" do
    test "collapses the same MAC in different formats to one canonical form" do
      canonical = "d0:21:f9:d2:e1:6d"

      for variant <- ["d021f9d2e16d", "d0:21:f9:d2:e1:6d", "D0-21-F9-D2-E1-6D", "d021.f9d2.e16d"] do
        assert Utils.normalize_interface_label(variant) == canonical
      end
    end

    test "keeps distinct MACs distinct (off-by-one byte is a different port)" do
      refute Utils.normalize_interface_label("d0:21:f9:d2:e1:6c") ==
               Utils.normalize_interface_label("d0:21:f9:d2:e1:6d")
    end

    test "leaves named ports untouched (only trims)" do
      assert Utils.normalize_interface_label("Slot: 0 Port: 22 Gigabit - Level") ==
               "Slot: 0 Port: 22 Gigabit - Level"

      assert Utils.normalize_interface_label("  GigabitEthernet1/0/1  ") == "GigabitEthernet1/0/1"
    end
  end

  describe "interface_id/3" do
    test "builds one id for a MAC-named port regardless of source format" do
      device = "sr:abc"

      assert Utils.interface_id(device, "d021f9d2e16d", nil) ==
               Utils.interface_id(device, "d0:21:f9:d2:e1:6d", 22)
    end

    test "falls back to ifindex when name is blank" do
      assert Utils.interface_id("sr:abc", "", 22) == "sr:abc/ifindex:22"
      assert Utils.interface_id("sr:abc", nil, nil) == nil
      assert Utils.interface_id(nil, "x", 1) == nil
    end
  end

  describe "base_metric_name/1" do
    test "strips collector interface suffixes" do
      assert Utils.base_metric_name("ifHCInOctets::ifindex:21") == "ifHCInOctets"
      assert Utils.base_metric_name("ifInUcastPkts") == "ifInUcastPkts"
      assert Utils.base_metric_name(nil) == nil
    end
  end
end
