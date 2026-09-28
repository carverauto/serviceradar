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
    * randomized MAC evidence alone never drives a merge: a MAC-only
      identifier conflict merges only when it holds a globally-unique MAC.
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
    # strong identifier: its normalized MAC. A randomized (locally administered)
    # MAC never identifies a device, so a conflict of those alone is refused.
    test "randomized-MAC-only identifier conflicts are blocked by policy" do
      matches = [
        {:mac, %{value: "021122334455", device_id: "sr:provisional-a"}},
        {:mac, %{value: "021122334466", device_id: "sr:provisional-b"}}
      ]

      refute MergePolicy.merge_allowed_for_matches?(matches)
      assert MergePolicy.blocked_merge_reason(matches) == "mac_only_conflict"
    end

    # A globally-unique MAC is hardware identity: the per-interface records of
    # one chassis converge on it (#4612).
    test "a MAC-only conflict holding a globally-unique MAC is mergeable" do
      matches = [
        {:mac, %{value: "001122334455", device_id: "sr:record-a"}},
        {:mac, %{value: "001122334466", device_id: "sr:record-b"}}
      ]

      assert MergePolicy.merge_allowed_for_matches?(matches)
    end

    test "a record linked only through a randomized MAC drops out of an allowed merge" do
      matches = [
        {:mac, %{value: "001122334455", device_id: "sr:canonical"}},
        {:mac, %{value: "001122334466", device_id: "sr:hardware-linked"}},
        {:mac, %{value: "021122334477", device_id: "sr:randomized-linked"}}
      ]

      assert MergePolicy.merge_allowed_for_matches?(matches)

      assert {["sr:hardware-linked"], ["sr:randomized-linked"]} =
               MergePolicy.split_randomized_mac_links(
                 ["sr:canonical", "sr:hardware-linked", "sr:randomized-linked"],
                 matches,
                 "sr:canonical"
               )
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
