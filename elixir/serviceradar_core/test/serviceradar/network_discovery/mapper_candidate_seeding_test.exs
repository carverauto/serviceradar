defmodule ServiceRadar.NetworkDiscovery.MapperCandidateSeedingTest do
  @moduledoc """
  A device's own interface addresses must never seed a separate device record.

  This is the mechanism that produced duplicate devices in production: an
  address on the device's own interface fell through to candidate seeding, found
  no device and no alias at that address, and minted a second record with no
  hostname and no MAC.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor

  describe "candidate_ips_for_role/4" do
    test "a router seeds nothing" do
      assert MapperResultsIngestor.candidate_ips_for_role(
               "router",
               ["192.168.1.143"],
               ["10.0.0.9"],
               ["192.168.2.55"]
             ) == []
    end

    # The regression. switchcff8f2 (192.168.2.55) reports its out-of-band
    # management address 192.168.1.143 on an `oob` interface. Because a
    # non-router receives no interface-derived aliases, .143 had no alias to
    # suppress it, and it became sr:eab6cd98 -- a second record for one switch.
    test "a switch does not seed its own out-of-band interface address" do
      candidates =
        MapperResultsIngestor.candidate_ips_for_role(
          "switch_l2",
          ["192.168.1.143"],
          [],
          ["192.168.2.55"]
        )

      assert candidates == [],
             "a device's own interface address must never become a separate device"
    end

    test "the same holds for the unknown role" do
      assert MapperResultsIngestor.candidate_ips_for_role(
               "unknown",
               ["192.168.1.143", "10.0.0.2"],
               [],
               ["192.168.2.55"]
             ) == []
    end

    test "genuinely different devices seen in the group are still seeded" do
      # mismatched_device_ips are OTHER device_ips in the group -- real
      # neighbours, which is what this seeding exists for. Narrowing must not
      # disable the feature.
      assert MapperResultsIngestor.candidate_ips_for_role(
               "switch_l2",
               ["192.168.1.143"],
               ["10.0.0.9", "10.0.0.10"],
               ["192.168.2.55"]
             ) == ["10.0.0.9", "10.0.0.10"]
    end

    test "an address already aliased is not re-seeded" do
      assert MapperResultsIngestor.candidate_ips_for_role(
               "switch_l2",
               [],
               ["10.0.0.9"],
               ["192.168.2.55", "10.0.0.9"]
             ) == []
    end

    test "duplicate neighbours are collapsed" do
      assert MapperResultsIngestor.candidate_ips_for_role(
               "switch_l2",
               [],
               ["10.0.0.9", "10.0.0.9"],
               []
             ) == ["10.0.0.9"]
    end
  end
end
