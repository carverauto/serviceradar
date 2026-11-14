defmodule ServiceRadar.Inventory.Identity.GuestIdentityGuardTest do
  @moduledoc """
  Which `integration_id` values name a hypervisor guest, and which pairs of guest-identity sets
  prove two records different machines, and which guests a record would gain beyond one
  (`GuestIdentityGuard`). The merge path is covered in `identity_reconciler_merge_guard_test.exs`
  and `blocked_fingerprint_test.exs`, resolution and registration in
  `sync_batch_resolution_test.exs`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.GuestIdentityGuard

  @integration "6f1d3c2a-0b4e-4c7a-9e21-5a8d7f3b1c01"
  @controller "0c9e8d7f-6a5b-4c3d-8e2f-1a0b9c8d7e02"
  @scope "proxmox:v3:#{@integration}:#{@controller}:cluster01"

  defp v3(vmid, kind \\ "qemu"), do: {:proxmox_v3, "#{@scope}:#{kind}:#{vmid}"}
  defp v2(vmid), do: {:proxmox_v2, "proxmox:v2:cluster01:vm:#{vmid}"}

  describe "guest_identity/1" do
    test "a v3 or v2 guest reference is a guest identity; anything else is not" do
      for {kind, vmid} <- [{"qemu", 136}, {"lxc", 137}] do
        ref = "#{@scope}:#{kind}:#{vmid}"
        assert GuestIdentityGuard.guest_identity(ref) == {:ok, {:proxmox_v3, ref}}
      end

      for ref <- ["proxmox:v2:cluster01:vm:136", "proxmox:v2:cluster01:lxc:137"] do
        assert GuestIdentityGuard.guest_identity(ref) == {:ok, {:proxmox_v2, ref}}
      end

      for value <- [
            "#{@scope}:node:pve01",
            "#{@scope}:cluster:cluster01",
            "proxmox:v2:cluster01:node:pve01",
            # A v3 reference that is not in its canonical form names nothing.
            "proxmox:v3:#{String.upcase(@integration)}:#{@controller}:cluster01:qemu:136",
            "awx:host:host01.example.com",
            "proxmox:vm:136",
            nil
          ] do
        assert GuestIdentityGuard.guest_identity(value) == :error
      end
    end
  end

  describe "conflict/2" do
    test "records holding different guests conflict" do
      cases = [
        # Another VMID: the record that absorbed guests 101 and 102 and guest 136's own.
        {[v3(101), v3(102)], [v3(136)]},
        # Another kind, cluster or integration with the same VMID.
        {[v3(136)], [v3(136, "lxc")]},
        {[v3(136)],
         [{:proxmox_v3, "proxmox:v3:#{@integration}:#{@controller}:cluster02:qemu:136"}]},
        {[v3(136)],
         [{:proxmox_v3, "proxmox:v3:#{@controller}:#{@controller}:cluster01:qemu:136"}]},
        # Overlapping sets where each holds a guest the other does not.
        {[v3(101), v3(136)], [v3(102), v3(136)]},
        {[v2(101)], [v2(136)]}
      ]

      for {a, b} <- cases do
        assert %{a: _, b: _} = GuestIdentityGuard.conflict(a, b), inspect({a, b})
        assert %{a: _, b: _} = GuestIdentityGuard.conflict(b, a), inspect({b, a})
      end
    end

    test "records that do not hold different guests do not conflict" do
      cases = [
        # The same guest, seen again.
        {[v3(136)], [v3(136)]},
        # One record holds every guest the other does.
        {[v3(136)], [v3(136), v3(101)]},
        # One holds no guest: an AWX host, an agent's record, a discovered record.
        {[], [v3(136)]},
        {[], []},
        # A legacy v2 reference does not say which v3 guest it is.
        {[v2(101)], [v3(136)]}
      ]

      for {a, b} <- cases do
        assert GuestIdentityGuard.conflict(a, b) == nil, inspect({a, b})
        assert GuestIdentityGuard.conflict(b, a) == nil, inspect({b, a})
      end
    end
  end

  describe "added_guests/2" do
    test "names the v3 guests a record would gain beyond its one guest" do
      ref = fn identity -> elem(identity, 1) end
      [g101, g102, g136] = Enum.map([v3(101), v3(102), v3(136)], ref)
      node = "#{@scope}:node:pve01"
      legacy = ref.(v2(102))

      cases = [
        # A record of one guest gains another, of the same or another integration.
        {[g101], [g136], [g136]},
        {[g101, node, "awx:host:host01.example.com"], [g136], [g136]},
        # A merged record of two guests gives a survivor of one, or of none, a guest.
        {[g101], [g101, g102], [g102]},
        {[], [g101, g102], [g101, g102]},
        # Nothing gained: the same guest, a first guest, or guests the record already holds.
        {[g101], [g101], []},
        {[], [g101], []},
        {[g101, g102], [g101], []},
        # Node references and legacy v2 references are not v3 guests.
        {[g101], [node, legacy], []},
        {[legacy], [g101], []}
      ]

      for {held, incoming, expected} <- cases do
        assert GuestIdentityGuard.added_guests(held, incoming) == expected,
               inspect({held, incoming})
      end
    end
  end
end
