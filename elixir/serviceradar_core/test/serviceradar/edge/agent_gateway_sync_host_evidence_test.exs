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
        build(%{host_macs: ["aa:bb:cc:dd:ee:01", "AABB.CCDD.EE02", "not-a-mac", ""]})

      assert update.mac_addresses == ["AABBCCDDEE01", "AABBCCDDEE02"]
    end

    test "accepts delimited-string fields and dedupes across accepted keys" do
      update =
        build(%{
          host_macs: "aa:bb:cc:dd:ee:01,AA-BB-CC-DD-EE-02",
          mac_addresses: ["AABBCCDDEE01"]
        })

      assert update.mac_addresses == ["AABBCCDDEE01", "AABBCCDDEE02"]
    end

    test "accepts host MACs nested under attrs metadata" do
      update = build(%{metadata: %{"host_macs" => ["aa:bb:cc:dd:ee:03"]}})

      assert update.mac_addresses == ["AABBCCDDEE03"]
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
end
