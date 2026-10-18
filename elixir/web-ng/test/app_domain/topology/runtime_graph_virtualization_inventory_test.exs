defmodule ServiceRadarWebNG.Topology.RuntimeGraphVirtualizationInventoryTest do
  use ServiceRadarWebNG.DataCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadarWebNG.Repo
  alias ServiceRadarWebNG.Topology.RuntimeGraph

  @moduletag :topology_atlas_db

  test "virtualization inventory SQL returns hosted topology rows for host and guest devices" do
    unique = System.unique_integer([:positive])
    observed_at = DateTime.truncate(DateTime.utc_now(), :second)
    host_uid = "sr:topology-pve-#{unique}"
    guest_uid = "sr:topology-vm-#{unique}"
    integration_id = Ecto.UUID.generate()
    controller_id = Ecto.UUID.generate()

    {:ok, host_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        integration_id,
        controller_id,
        "synthetic-cluster",
        "node",
        "pve-topology-#{unique}"
      )

    {:ok, guest_identity} =
      IntegrationIdentity.proxmox_v3_fields(integration_id, controller_id, "synthetic-cluster", "qemu", "100")

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
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(host_identity, %{
          provider: "proxmox",
          device_uid: host_uid,
          name: "pve-topology-#{unique}",
          status: "online",
          observed_at: observed_at
        })
      )
      |> Ash.create(actor: system_actor())

    {:ok, _guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(guest_identity, %{
          provider: "proxmox",
          host_id: host.id,
          device_uid: guest_uid,
          name: "vm-topology-#{unique}",
          guest_type: "vm",
          vmid: 100,
          status: "running",
          observed_at: observed_at
        })
      )
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

  test "virtualization inventory SQL skips legacy rows that a v3 row supersedes" do
    unique = System.unique_integer([:positive])
    integration_id = Ecto.UUID.generate()
    controller_id = Ecto.UUID.generate()
    v3_host_uid = "sr:topology-v3-pve-#{unique}"
    v3_guest_uid = "sr:topology-v3-vm-#{unique}"
    legacy_host_uid = "sr:topology-legacy-pve-#{unique}"
    superseded_host_uid = "sr:topology-superseded-pve-#{unique}"
    kept_guest_uid = "sr:topology-kept-vm-#{unique}"
    superseded_guest_uid = "sr:topology-superseded-vm-#{unique}"
    orphaned_guest_uid = "sr:topology-orphaned-vm-#{unique}"
    node = "pve-current-#{unique}"

    Repo.insert_all(
      "ocsf_devices",
      Enum.map(
        [
          v3_host_uid,
          v3_guest_uid,
          legacy_host_uid,
          superseded_host_uid,
          kept_guest_uid,
          superseded_guest_uid,
          orphaned_guest_uid
        ],
        &%{uid: &1, type_id: 1}
      )
    )

    {:ok, host_identity} =
      IntegrationIdentity.proxmox_v3_fields(integration_id, controller_id, "synthetic-cluster", "node", node)

    {:ok, guest_identity} =
      IntegrationIdentity.proxmox_v3_fields(integration_id, controller_id, "synthetic-cluster", "qemu", "300")

    {:ok, v3_host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(host_identity, %{provider: "proxmox", device_uid: v3_host_uid, name: node})
      )
      |> Ash.create(actor: system_actor())

    {:ok, _v3_guest} =
      VirtualizationGuest
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(guest_identity, %{
          provider: "proxmox",
          host_id: v3_host.id,
          device_uid: v3_guest_uid,
          guest_type: "vm",
          vmid: 300
        })
      )
      |> Ash.create(actor: system_actor())

    # A legacy host with no v3 twin, and one that the v3 host superseded.
    legacy_host_id = insert_legacy_host("proxmox:node:pve-retired-#{unique}", legacy_host_uid)
    superseded_host_id = insert_legacy_host("proxmox:node:#{node}", superseded_host_uid)
    insert_resolved_alias("host", "proxmox:node:#{node}", host_identity.provider_ref)

    insert_legacy_guest("proxmox:guest:pve-retired-#{unique}:qemu:299", legacy_host_id, kept_guest_uid)

    superseded_guest_ref = "proxmox:guest:#{node}:qemu:300"
    insert_legacy_guest(superseded_guest_ref, legacy_host_id, superseded_guest_uid)
    insert_resolved_alias("guest", superseded_guest_ref, guest_identity.provider_ref)

    insert_legacy_guest("proxmox:guest:#{node}:qemu:301", superseded_host_id, orphaned_guest_uid)

    assert {:ok, %{rows: rows}} =
             Repo.query(RuntimeGraph.virtualization_inventory_links_query(), [nil])

    links =
      rows
      |> Enum.map(fn [row] -> {row["local_device_id"], row["neighbor_device_id"]} end)
      |> Enum.filter(fn {host_uid, _guest_uid} ->
        host_uid in [v3_host_uid, legacy_host_uid, superseded_host_uid]
      end)
      |> Enum.sort()

    assert links == Enum.sort([{v3_host_uid, v3_guest_uid}, {legacy_host_uid, kept_guest_uid}])
  end

  test "fetch_topology_links_with_virtualization/1 degrades gracefully when the inventory query fails" do
    primary_rows = [%{local_device_id: "sr:a", neighbor_device_id: "sr:b"}]

    assert {:error, _} = Repo.query("SELECT 1 / 0", [])

    assert {:ok, ^primary_rows} =
             RuntimeGraph.fetch_topology_links_with_virtualization(primary_rows)
  end

  # New Proxmox rows must be v3, so a pre-migration row needs the guard off.
  defp insert_legacy_host(provider_ref, device_uid) do
    insert_legacy_row(
      "virtualization_hosts",
      """
      INSERT INTO platform.virtualization_hosts (id, provider, provider_ref, device_uid, name)
      VALUES (gen_random_uuid(), 'proxmox', $1, $2, 'legacy node')
      RETURNING id::text
      """,
      [provider_ref, device_uid]
    )
  end

  defp insert_legacy_guest(provider_ref, host_id, device_uid) do
    insert_legacy_row(
      "virtualization_guests",
      """
      INSERT INTO platform.virtualization_guests (id, provider, provider_ref, host_id, device_uid, guest_type)
      VALUES (gen_random_uuid(), 'proxmox', $1, ($2::text)::uuid, $3, 'vm')
      RETURNING id::text
      """,
      [provider_ref, host_id, device_uid]
    )
  end

  defp insert_legacy_row(table, sql, params) do
    guard = "#{table}_identity_immutable_guard"
    Repo.query!("ALTER TABLE platform.#{table} DISABLE TRIGGER #{guard}")

    try do
      [[id]] = Repo.query!(sql, params).rows
      id
    after
      Repo.query!("ALTER TABLE platform.#{table} ENABLE TRIGGER #{guard}")
    end
  end

  defp insert_resolved_alias(resource_kind, legacy_ref, target_ref) do
    Repo.query!(
      """
      INSERT INTO platform.virtualization_identity_aliases (
        id, provider, resource_kind, legacy_provider_ref, target_provider_ref, status,
        candidate_provider_refs
      )
      VALUES (gen_random_uuid(), 'proxmox', $1, $2, $3, 'resolved', ARRAY[$3])
      """,
      [resource_kind, legacy_ref, target_ref]
    )
  end
end
