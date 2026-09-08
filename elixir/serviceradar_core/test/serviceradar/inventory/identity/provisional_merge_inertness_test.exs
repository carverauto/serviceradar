defmodule ServiceRadar.Inventory.Identity.ProvisionalMergeInertnessTest do
  @moduledoc """
  Unit coverage (no database) pinning the merge-inertness guarantees for
  provisional topology-sighted devices (spec: network-discovery, "Endpoint
  attachment identity promotion" / "Provisional identities are merge-inert"):

    * a provisional device MAY be merged INTO a corroborated device (subject
      to the existing identity-proof policy), but a corroborated device is
      never merged INTO a provisional one (no identifier absorption);
    * devices with distinct registered MACs are never merged when either side
      is a provisional topology-sighted device;
    * topology evidence alone never drives a merge: provisional topology
      devices only ever carry MAC identifiers, and MAC-only identifier
      conflicts are categorically blocked by MergePolicy.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.MergeEngine
  alias ServiceRadar.Inventory.Identity.MergePolicy

  describe "provisional_topology_merge_guard/3 decision table" do
    test "merges not involving provisional topology devices are untouched" do
      assert MergeEngine.provisional_topology_merge_guard(false, false, false) == nil
      assert MergeEngine.provisional_topology_merge_guard(false, false, true) == nil
    end

    test "corroborated device is never merged INTO a provisional device (absorb direction)" do
      assert MergeEngine.provisional_topology_merge_guard(false, true, false) ==
               :provisional_identity_absorb

      assert MergeEngine.provisional_topology_merge_guard(false, true, true) ==
               :provisional_identity_absorb
    end

    test "provisional device may merge INTO a corroborated device when MACs do not conflict" do
      assert MergeEngine.provisional_topology_merge_guard(true, false, false) == nil
    end

    test "distinct registered MACs block the merge in every direction" do
      assert MergeEngine.provisional_topology_merge_guard(true, false, true) ==
               :distinct_mac_identity

      assert MergeEngine.provisional_topology_merge_guard(true, true, true) ==
               :distinct_mac_identity
    end

    test "two provisional devices with compatible MAC evidence are not blocked by this guard" do
      assert MergeEngine.provisional_topology_merge_guard(true, true, false) == nil
    end
  end

  describe "topology evidence alone never drives a merge" do
    # A provisional topology-sighted device carries exactly one class of
    # strong identifier: its normalized MAC. Any identifier conflict it can
    # participate in is therefore MAC-only, which MergePolicy categorically
    # refuses to auto-merge — identity proof requires a non-MAC strong
    # identifier (agent/armis/integration/netbox) corroboration.
    test "MAC-only identifier conflicts are blocked by policy" do
      matches = %{mac: %{value: "001122334455", device_id: "sr:provisional-a"}}

      refute MergePolicy.merge_allowed_for_matches?(matches)
      assert MergePolicy.blocked_merge_reason(matches) == "mac_only_conflict"
    end

    test "agent-corroborated conflicts remain mergeable (identity proof present)" do
      matches = %{
        agent_id: %{value: "agent-1", device_id: "sr:corroborated-a"},
        mac: %{value: "001122334455", device_id: "sr:provisional-a"}
      }

      assert MergePolicy.merge_allowed_for_matches?(matches)
    end
  end
end
