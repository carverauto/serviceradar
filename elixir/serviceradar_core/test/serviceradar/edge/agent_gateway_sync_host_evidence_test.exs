defmodule ServiceRadar.Edge.AgentGatewaySyncHostEvidenceTest do
  @moduledoc """
  Unit coverage for task 6.1 (`refactor-device-identity-reconciliation`):
  agent enrollment surfaces host evidence in the device update that DIRE
  consumes — host interface MACs (normalized, validated, atomic) plus
  hostname/machine-id metadata for future DIRE-side bridging.

  These tests are pure (no database): they exercise the device-update build
  path that `ensure_device_for_agent/2` feeds into
  `IdentityReconciler.resolve_device_id/2` and `register_identifiers/3`.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Edge.AgentGatewaySync
  alias ServiceRadar.Inventory.IdentityReconciler

  defp build(attrs) do
    AgentGatewaySync.build_device_update_from_agent("agent-evidence-test", attrs)
  end

  defp iface(name, kind, mac, permanent_mac, provenance) do
    %{
      name: name,
      mac: mac,
      permanent_mac: permanent_mac,
      ips: [],
      oper_state: "up",
      kind: kind,
      mac_provenance: provenance,
      master: ""
    }
  end

  describe "build_device_update_from_agent/2 — today's gateway payload (no MACs)" do
    test "carries no MAC evidence but keeps agent_id and host facts" do
      update =
        AgentGatewaySync.build_device_update_from_agent("agent-1", %{
          hostname: "host-a",
          os: "linux",
          arch: "amd64",
          partition: "default",
          source_ip: "10.0.0.5",
          capabilities: ["sysmon"]
        })

      assert update.mac == nil
      assert update.mac_addresses == []
      assert update.ip == "10.0.0.5"
      assert update.partition == "default"
      assert update.metadata["agent_id"] == "agent-1"
      assert update.metadata["hostname"] == "host-a"
      assert update.metadata["hostname_normalized"] == "host-a"
      refute Map.has_key?(update.metadata, "machine_id")
    end
  end

  describe "build_device_update_from_agent/2 — host interface MACs" do
    test "normalizes MACs from a host_macs list and drops invalid entries" do
      update =
        build(%{host_macs: ["00:1a:2c:00:53:01", "001A.2C00.5302", "not-a-mac", ""]})

      assert update.mac_addresses == ["001A2C005301", "001A2C005302"]
    end

    test "accepts delimited-string fields and dedupes across accepted keys" do
      update =
        build(%{
          host_macs: "00:1a:2c:00:53:01,00-1A-2C-00-53-02",
          mac_addresses: ["001A2C005301"]
        })

      assert update.mac_addresses == ["001A2C005301", "001A2C005302"]
    end

    test "accepts host MACs nested under attrs metadata" do
      update = build(%{metadata: %{"host_macs" => ["00:1a:2c:00:53:03"]}})

      assert update.mac_addresses == ["001A2C005303"]
    end

    test "never emits a comma blob or malformed value" do
      update =
        build(%{
          host_macs: "001AA0B94040,001422F42A2A,70B3D59EDC93,garbage,00:11"
        })

      assert update.mac_addresses == ["001AA0B94040", "001422F42A2A", "70B3D59EDC93"]

      Enum.each(update.mac_addresses, fn mac ->
        assert mac =~ ~r/^[0-9A-F]{12}$/
        refute String.contains?(mac, ",")
      end)
    end

    test "extract_strong_identifiers picks up host MACs alongside agent_id" do
      update =
        AgentGatewaySync.build_device_update_from_agent("agent-x", %{
          host_macs: ["00:1a:2b:0d:ee:0f"],
          partition: "default"
        })

      ids = IdentityReconciler.extract_strong_identifiers(update)

      assert ids.agent_id == "agent-x"
      assert ids.macs == ["001A2B0DEE0F"]
      assert ids.mac == "001A2B0DEE0F"
    end
  end

  describe "build_device_update_from_agent/2 — bridging metadata (not identifiers)" do
    test "surfaces normalized hostname and machine_id in metadata" do
      update =
        build(%{
          hostname: "  Pod-ABC  ",
          machine_id: "  3f1a9c2e8b7d4e5fa6b1c2d3e4f5a6b7  "
        })

      assert update.metadata["hostname_normalized"] == "pod-abc"
      assert update.metadata["machine_id"] == "3f1a9c2e8b7d4e5fa6b1c2d3e4f5a6b7"
    end

    test "accepts machine_id nested under attrs metadata" do
      update = build(%{metadata: %{"machine_id" => "abc123"}})

      assert update.metadata["machine_id"] == "abc123"
    end

    test "hostname/machine-id never become identifier values" do
      update =
        build(%{
          hostname: "pod-host-1",
          machine_id: "3f1a9c2e8b7d4e5fa6b1c2d3e4f5a6b7"
        })

      ids = IdentityReconciler.extract_strong_identifiers(update)

      assert ids.macs == []
      assert ids.mac == nil
      # No identifier slot carries the hostname or machine-id values.
      refute "pod-host-1" in Map.values(ids)
      refute "3f1a9c2e8b7d4e5fa6b1c2d3e4f5a6b7" in Map.values(ids)
    end
  end

  # `link-agent-host-by-strong-identity`: the agent reports its whole classified inventory and
  # core keeps only the permanent, globally administered MACs of physical NICs and bond members.
  describe "build_device_update_from_agent/2 — classified host interface inventory" do
    test "a bridge, a bond, a veth, a tap and a randomized MAC are not identity; the NICs are" do
      update =
        build(%{
          # What an older core would read: the announced bridge's MAC.
          host_macs: ["00:00:5e:00:53:a1"],
          host_interfaces: [
            iface(
              "eno1",
              :HOST_INTERFACE_KIND_PHYSICAL,
              "00:00:5e:00:53:a1",
              "00:00:5e:00:53:a1",
              :MAC_PROVENANCE_PERMANENT
            ),
            # A bond member's MAC is the bond's; its own is perm_hwaddr.
            iface(
              "eno2",
              :HOST_INTERFACE_KIND_PHYSICAL,
              "00:00:5e:00:53:a1",
              "00:00:5e:00:53:a2",
              :MAC_PROVENANCE_ASSIGNED
            ),
            iface(
              "vmbr0",
              :HOST_INTERFACE_KIND_BRIDGE,
              "00:00:5e:00:53:a1",
              nil,
              :MAC_PROVENANCE_INHERITED
            ),
            iface(
              "bond0",
              :HOST_INTERFACE_KIND_BOND,
              "00:00:5e:00:53:a1",
              nil,
              :MAC_PROVENANCE_ASSIGNED
            ),
            iface(
              "veth7c1",
              :HOST_INTERFACE_KIND_VIRTUAL,
              "02:00:5e:00:53:b1",
              nil,
              :MAC_PROVENANCE_RANDOM
            ),
            # A guest NIC's host side can carry a globally administered MAC; it is a guest's.
            iface(
              "tap101i0",
              :HOST_INTERFACE_KIND_VIRTUAL,
              "00:00:5e:00:53:b2",
              "00:00:5e:00:53:b2",
              :MAC_PROVENANCE_PERMANENT
            ),
            iface(
              "wlp2s0",
              :HOST_INTERFACE_KIND_PHYSICAL,
              "02:00:5e:00:53:b3",
              nil,
              :MAC_PROVENANCE_ASSIGNED
            ),
            iface(
              "eno3",
              :HOST_INTERFACE_KIND_PHYSICAL,
              "02:00:5e:00:53:b4",
              "02:00:5e:00:53:b4",
              :MAC_PROVENANCE_PERMANENT
            ),
            iface(
              "lo",
              :HOST_INTERFACE_KIND_LOOPBACK,
              "00:00:00:00:00:00",
              nil,
              :MAC_PROVENANCE_UNSPECIFIED
            )
          ]
        })

      assert update.mac_addresses == ["00005E0053A1", "00005E0053A2"]
    end

    test "a virtual-only inventory with a locally administered announced MAC identifies nothing" do
      update =
        build(%{
          host_macs: ["02:00:5e:00:53:c1"],
          host_interfaces: [
            iface(
              "veth3e9",
              :HOST_INTERFACE_KIND_VIRTUAL,
              "02:00:5e:00:53:c1",
              nil,
              :MAC_PROVENANCE_RANDOM
            ),
            iface(
              "tap102i0",
              :HOST_INTERFACE_KIND_VIRTUAL,
              "00:00:5e:00:53:c2",
              nil,
              :MAC_PROVENANCE_RANDOM
            )
          ]
        })

      assert update.mac_addresses == []
    end

    # Outside Linux the agent cannot classify; core keeps the announced interface's MAC, as
    # it did before the inventory existed.
    test "an unclassified inventory falls back to host_macs" do
      update =
        build(%{
          host_macs: ["00:00:5e:00:53:d1"],
          host_interfaces: [
            iface(
              "en0",
              :HOST_INTERFACE_KIND_UNSPECIFIED,
              "00:00:5e:00:53:d1",
              nil,
              :MAC_PROVENANCE_UNSPECIFIED
            ),
            iface(
              "en1",
              :HOST_INTERFACE_KIND_UNSPECIFIED,
              "00:00:5e:00:53:d2",
              nil,
              :MAC_PROVENANCE_UNSPECIFIED
            )
          ]
        })

      assert update.mac_addresses == ["00005E0053D1"]
    end
  end
end
