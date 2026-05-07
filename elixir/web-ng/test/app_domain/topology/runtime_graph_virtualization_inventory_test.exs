defmodule ServiceRadarWebNG.Topology.RuntimeGraphVirtualizationInventoryTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  test "virtualization inventory SQL returns hosted topology rows for host and guest devices" do
    unique = System.unique_integer([:positive])
    observed_at = DateTime.truncate(DateTime.utc_now(), :second)
    host_uid = "sr:topology-pve-#{unique}"
    guest_uid = "sr:topology-vm-#{unique}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: host_uid,
        type_id: 1,
        hostname: "pve-topology-#{unique}",
        ip: "192.0.2.10",
        is_available: true,
        first_seen_time: observed_at,
        last_seen_time: observed_at
      },
      %{
        uid: guest_uid,
        type_id: 1,
        hostname: "vm-topology-#{unique}",
        ip: "192.0.2.20",
        is_available: true,
        first_seen_time: observed_at,
        last_seen_time: observed_at
      }
    ])

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:node:pve-topology-#{unique}",
        device_uid: host_uid,
        name: "pve-topology-#{unique}",
        status: "online",
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(:create, %{
        provider: "proxmox",
        provider_ref: "proxmox:guest:pve-topology-#{unique}:qemu:100",
        host_id: host.id,
        device_uid: guest_uid,
        name: "vm-topology-#{unique}",
        guest_type: "vm",
        vmid: 100,
        status: "running",
        observed_at: observed_at
      })
      |> Ash.create(actor: system_actor())

    assert {:ok, %{rows: rows}} =
             Repo.query(RuntimeGraph.virtualization_inventory_links_query(), [50])

    row =
      rows
      |> Enum.map(fn [row] -> row end)
      |> Enum.find(&(&1["local_device_id"] == host_uid and &1["neighbor_device_id"] == guest_uid))

    assert row["local_device_ip"] == "192.0.2.10"
    assert row["neighbor_mgmt_addr"] == "192.0.2.20"
    assert row["neighbor_system_name"] == "vm-topology-#{unique}"
    assert row["local_if_name"] == "hosted-guests"
    assert row["protocol"] == "proxmox-inventory"
    assert row["evidence_class"] == "hosted-virtual"
    assert row["confidence_reason"] == "authoritative_virtualization_inventory"
    assert row["metadata"]["relation_type"] == "HOSTED_ON"
    assert row["metadata"]["topology_plane"] == "hosted"
    assert row["metadata"]["virtualization_provider"] == "proxmox"
    assert row["metadata"]["virtualization_guest_vmid"] == 100
  end
end
