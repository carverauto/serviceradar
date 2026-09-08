defmodule ServiceRadar.Inventory.Identity.IdsProxmoxGuardTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.Identity.Ids
  alias ServiceRadar.Inventory.Sync.IdentifierRecords

  test "unscoped primaries cannot classify, register, or seed a device identity" do
    for value <- [
          "proxmox:vm:guest01.example.com",
          "proxmox:container:guest01.example.com",
          "proxmox:hypervisor:host01.example.com",
          "proxmox:vm:901",
          "proxmox:vm:qemu/901",
          "proxmox:guest:host01.example.com:qemu:901",
          "proxmox:qemu:host01.example.com:901"
        ] do
      update = %{
        metadata: %{"integration_id" => value, "integration_type" => "proxmox"},
        source: "proxmox",
        ip: "192.0.2.21",
        mac: nil,
        partition: "default"
      }

      ids = Ids.extract_strong_identifiers(update)
      assert ids.integration_id == nil
      refute Ids.has_strong_identifier?(ids)
      assert Ids.get_identifier_values(:integration_id, ids) == []
      assert IdentifierRecords.build_identifier_records([{update, "sr:synthetic-device"}]) == []

      stale_ids = Map.put(ids, :integration_id, value)
      refute Ids.has_strong_identifier?(stale_ids)
      assert Ids.get_identifier_value(stale_ids, :integration_id) == nil
      assert Ids.highest_priority_identifier(stale_ids) == Ids.highest_priority_identifier(ids)

      assert Ids.generate_deterministic_device_id(stale_ids) ==
               Ids.generate_deterministic_device_id(ids)

      other = Ids.extract_strong_identifiers(%{update | ip: "192.0.2.22"})

      refute Ids.generate_deterministic_device_id(ids) ==
               Ids.generate_deterministic_device_id(other)
    end
  end

  test "stale bridges cannot bypass the cluster scope requirement" do
    ids = %{
      integration_id: "proxmox:v2:cluster-a:vm:901",
      legacy_integration_ids: [
        "proxmox:vm:901",
        "proxmox:vm:qemu/901",
        "proxmox:guest:host01.example.com:qemu:901",
        "proxmox:vm:guest01.example.com"
      ]
    }

    assert Ids.get_identifier_values(:integration_id, ids) == [ids.integration_id]
    assert Ids.has_strong_identifier?(ids)
  end

  test "scoped identity stays strong and distinguishes clusters" do
    left = %{integration_id: "proxmox:v2:cluster-a:vm:901"}
    right = %{integration_id: "proxmox:v2:cluster-b:vm:901"}

    assert Ids.has_strong_identifier?(left)
    assert Ids.get_identifier_value(left, :integration_id) == left.integration_id

    refute Ids.generate_deterministic_device_id(left) ==
             Ids.generate_deterministic_device_id(right)
  end

  test "other providers remain strong" do
    ids = %{integration_id: "netbox:device:42"}
    assert Ids.has_strong_identifier?(ids)
    assert Ids.get_identifier_values(:integration_id, ids) == [ids.integration_id]
  end
end
