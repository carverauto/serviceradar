defmodule ServiceRadarWebNGWeb.Helpers.InterfaceTypesTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Helpers.InterfaceTypes

  describe "humanize/1" do
    test "returns human-readable name for known Ethernet types" do
      assert InterfaceTypes.humanize("ethernetCsmacd") == "Ethernet"
      assert InterfaceTypes.humanize("fastEther") == "Fast Ethernet"
      assert InterfaceTypes.humanize("gigabitEthernet") == "Gigabit Ethernet"
    end

    test "returns human-readable name for loopback and virtual types" do
      assert InterfaceTypes.humanize("softwareLoopback") == "Loopback"
      assert InterfaceTypes.humanize("tunnel") == "Tunnel"
      assert InterfaceTypes.humanize("l2vlan") == "VLAN"
      assert InterfaceTypes.humanize("bridge") == "Bridge"
      assert InterfaceTypes.humanize("propVirtual") == "Virtual"
    end

    test "returns human-readable name for WAN/Serial types" do
      assert InterfaceTypes.humanize("ppp") == "PPP"
      assert InterfaceTypes.humanize("frameRelay") == "Frame Relay"
      assert InterfaceTypes.humanize("atm") == "ATM"
      assert InterfaceTypes.humanize("adsl") == "ADSL"
      assert InterfaceTypes.humanize("vdsl2") == "VDSL2"
    end

    test "returns human-readable name for wireless types" do
      assert InterfaceTypes.humanize("ieee80211") == "WiFi (802.11)"
    end

    test "returns human-readable name for numeric type codes" do
      assert InterfaceTypes.humanize("6") == "Ethernet"
      assert InterfaceTypes.humanize("24") == "Loopback"
      assert InterfaceTypes.humanize("131") == "Tunnel"
      assert InterfaceTypes.humanize("135") == "VLAN"
    end

    test "returns human-readable name for integer type codes" do
      assert InterfaceTypes.humanize(6) == "Ethernet"
      assert InterfaceTypes.humanize(24) == "Loopback"
    end

    test "returns original value for unknown types" do
      assert InterfaceTypes.humanize("unknownType123") == "unknownType123"
      assert InterfaceTypes.humanize("customInterface") == "customInterface"
    end

    test "returns formatted string for unknown integer types" do
      assert InterfaceTypes.humanize(999) == "Type 999"
    end

    test "handles nil input" do
      assert InterfaceTypes.humanize(nil) == "—"
    end

    test "handles empty string input" do
      assert InterfaceTypes.humanize("") == "—"
    end

    test "handles non-string/integer input" do
      assert InterfaceTypes.humanize(:atom) == "—"
      assert InterfaceTypes.humanize([]) == "—"
    end
  end

  describe "all_mappings/0" do
    test "returns a map of all type mappings" do
      mappings = InterfaceTypes.all_mappings()
      assert is_map(mappings)
      assert Map.get(mappings, "ethernetCsmacd") == "Ethernet"
      assert Map.get(mappings, "softwareLoopback") == "Loopback"
    end

    test "contains expected number of mappings" do
      mappings = InterfaceTypes.all_mappings()
      # Should have a reasonable number of mappings
      assert map_size(mappings) > 30
    end
  end

  describe "known?/1" do
    test "returns true for known types" do
      assert InterfaceTypes.known?("ethernetCsmacd") == true
      assert InterfaceTypes.known?("softwareLoopback") == true
      assert InterfaceTypes.known?("6") == true
    end

    test "returns false for unknown types" do
      assert InterfaceTypes.known?("unknownType123") == false
      assert InterfaceTypes.known?("customInterface") == false
    end

    test "returns false for nil" do
      assert InterfaceTypes.known?(nil) == false
    end
  end
end
