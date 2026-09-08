defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.IntegrationIdentity

  @observed_at ~U[2026-05-09 12:00:00Z]

  test "advertises support for provider-neutral hypervisor details" do
    payload = %{
      "details" =>
        Jason.encode!(%{
          "schema" => "serviceradar.hypervisor_enrichment.v1",
          "provider" => "vsphere"
        })
    }

    assert HypervisorEnrichmentIngestor.supports?(payload, %{})
    assert HypervisorEnrichmentIngestor.supports?([%{"status" => "OK"}, payload], %{})
    refute HypervisorEnrichmentIngestor.supports?(%{"details" => %{"schema" => "unknown"}}, %{})
  end

  test "maps a synthetic vSphere-shaped envelope into shared virtualization records" do
    parent = self()

    payload = %{
      "observed_at" => DateTime.to_iso8601(@observed_at),
      "details" => Jason.encode!(vsphere_envelope())
    }

    assert :ok =
             HypervisorEnrichmentIngestor.ingest(payload, %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    assert [cluster] = records.clusters
    assert cluster.provider == "vsphere"
    assert cluster.provider_ref == "vsphere:vcenter-a:cluster:domain-c7"
    assert cluster.name == "Production"

    assert [host] = records.hosts
    assert host.provider == "vsphere"
    assert host.provider_ref == "vsphere:vcenter-a:host:host-42"
    assert host.cluster_provider_ref == cluster.provider_ref

    assert [guest] = records.guests
    assert guest.provider_ref == "vsphere:vcenter-a:guest:vm-100"
    assert guest.host_provider_ref == host.provider_ref
    assert guest.guest_type == "vm"

    assert [datastore] = records.datastores
    assert datastore.provider_ref == "vsphere:vcenter-a:datastore:datastore-11"
    assert datastore.total_bytes == 1_000_000

    assert [disk] = records.host_disks
    assert disk.provider_ref == "vsphere:vcenter-a:disk:naa.123"
    assert disk.model == "Virtual Disk"

    assert [nic] = records.network_interfaces
    assert nic.guest_provider_ref == guest.provider_ref
    assert nic.mac_address == "00:50:56:aa:bb:cc"
    assert nic.ip_addresses == ["10.10.20.30/24"]

    assert [storage] = records.storage_systems
    assert storage.provider_ref == "vsphere:vcenter-a:storage:vsan"
    assert storage.storage_system_type == "vsan"

    assert [console_target] = records.console_targets
    assert console_target.provider == "vsphere"
    assert console_target.provider_ref == "vsphere:vcenter-a:guest:vm-100"
    assert console_target.target_ref == "vsphere:vcenter-a:guest:vm-100"
    assert console_target.target_type == "guest"
    assert console_target.protocol == "vsphere-console"
    assert console_target.transport == "framebuffer"
    assert console_target.credential_purpose == "console_access"
    assert console_target.capabilities == ["data", "resize", "close"]

    refute sensitive_value?(records)
  end

  test "deduplicates shared records by provider and provider ref using newest observed_at" do
    stale = %{
      provider: "vsphere",
      provider_ref: "vsphere:vcenter-a:host:host-42",
      name: "old",
      observed_at: DateTime.add(@observed_at, -60, :second)
    }

    fresh = %{
      provider: "vsphere",
      provider_ref: "vsphere:vcenter-a:host:host-42",
      name: "new",
      observed_at: @observed_at
    }

    records =
      HypervisorEnrichmentIngestor.empty_records()
      |> Map.put(:hosts, [stale, fresh])
      |> HypervisorEnrichmentIngestor.dedupe_records()

    assert [%{name: "new"}] = records.hosts
  end

  test "rejects partial or mismatched Proxmox v3 records before persistence" do
    provider_ref =
      "proxmox:v3:11111111-1111-4111-8111-111111111111:" <>
        "22222222-2222-4222-8222-222222222222:lab:node:pve01"

    records =
      Map.put(HypervisorEnrichmentIngestor.empty_records(), :hosts, [
        %{
          provider: "proxmox",
          provider_ref: provider_ref,
          identity_version: 3,
          identity_state: :authoritative,
          integration_id: "11111111-1111-4111-8111-111111111111",
          controller_id: "22222222-2222-4222-8222-222222222222",
          native_cluster_id: "lab",
          object_kind: "node",
          native_object_id: "pve02",
          provider_instance_ref:
            "proxmox:v3:11111111-1111-4111-8111-111111111111:" <>
              "22222222-2222-4222-8222-222222222222:lab"
        }
      ])

    assert {:error, {:invalid_proxmox_v3_identity, ^provider_ref}} =
             HypervisorEnrichmentIngestor.persist_records(records, actor: %{})
  end

  test "rejects new legacy Proxmox records before persistence" do
    provider_ref = "proxmox:node:pve-legacy"

    records =
      Map.put(HypervisorEnrichmentIngestor.empty_records(), :hosts, [
        %{provider: "proxmox", provider_ref: provider_ref, name: "pve-legacy"}
      ])

    assert {:error, {:proxmox_v3_identity_required, ^provider_ref}} =
             HypervisorEnrichmentIngestor.persist_records(records, actor: %{})
  end

  test "rejects self-asserted Proxmox v3 scope from a generic persistence path" do
    trusted_scope = %{
      integration_id: "11111111-1111-4111-8111-111111111111",
      controller_id: "22222222-2222-4222-8222-222222222222",
      partition_id: "farm01"
    }

    {:ok, identity} =
      IntegrationIdentity.proxmox_v3_fields(
        trusted_scope.integration_id,
        trusted_scope.controller_id,
        "lab",
        :node,
        "pve01"
      )

    records =
      Map.put(HypervisorEnrichmentIngestor.empty_records(), :hosts, [
        Map.merge(identity, %{provider: "proxmox", name: "pve01"})
      ])

    assert {:error, :missing_trusted_proxmox_source_scope} =
             HypervisorEnrichmentIngestor.persist_records(records, actor: %{})

    assert {:error, :proxmox_source_scope_mismatch} =
             HypervisorEnrichmentIngestor.persist_records(records,
               actor: %{},
               source_scope: %{
                 integration_id: Ecto.UUID.generate(),
                 controller_id: trusted_scope.controller_id,
                 partition_id: trusted_scope.partition_id
               }
             )

    records_with_global_child =
      Map.put(records, :network_interfaces, [
        %{
          provider: "proxmox",
          provider_ref: "proxmox:nic:pve01:vmbr0",
          host_provider_ref: identity.provider_ref,
          name: "vmbr0"
        }
      ])

    assert {:error, :proxmox_source_scope_mismatch} =
             HypervisorEnrichmentIngestor.persist_records(records_with_global_child,
               actor: %{},
               source_scope: trusted_scope
             )
  end

  defp vsphere_envelope do
    %{
      "schema" => "serviceradar.hypervisor_enrichment.v1",
      "provider" => "vsphere",
      "clusters" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:cluster:domain-c7",
          "name" => "Production",
          "status" => "green",
          "metadata" => %{"secret" => "drop-me", "moid" => "domain-c7"}
        }
      ],
      "hosts" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:host:host-42",
          "cluster_provider_ref" => "vsphere:vcenter-a:cluster:domain-c7",
          "device_uid" => "sr:device:esxi-42",
          "name" => "esxi-42.example",
          "status" => "connected",
          "cpu_ratio" => 0.22,
          "memory_used_bytes" => 4096,
          "memory_total_bytes" => 8192
        }
      ],
      "guests" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:guest:vm-100",
          "host_provider_ref" => "vsphere:vcenter-a:host:host-42",
          "name" => "app-01",
          "guest_type" => "vm",
          "status" => "poweredOn"
        }
      ],
      "datastores" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:datastore:datastore-11",
          "cluster_provider_ref" => "vsphere:vcenter-a:cluster:domain-c7",
          "host_provider_ref" => "vsphere:vcenter-a:host:host-42",
          "name" => "datastore1",
          "storage_type" => "vmfs",
          "used_bytes" => 250_000,
          "total_bytes" => 1_000_000
        }
      ],
      "host_disks" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:disk:naa.123",
          "host_provider_ref" => "vsphere:vcenter-a:host:host-42",
          "device_uid" => "sr:device:esxi-42",
          "by_id" => "naa.123",
          "model" => "Virtual Disk",
          "health" => "green"
        }
      ],
      "guest_network_interfaces" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:guest-nic:vm-100:4000",
          "host_provider_ref" => "vsphere:vcenter-a:host:host-42",
          "guest_provider_ref" => "vsphere:vcenter-a:guest:vm-100",
          "name" => "Network adapter 1",
          "interface_type" => "vmxnet3",
          "mac_address" => "00:50:56:aa:bb:cc",
          "ip_addresses" => ["10.10.20.30/24"],
          "source" => "guest_tools"
        }
      ],
      "storage_systems" => [
        %{
          "provider_ref" => "vsphere:vcenter-a:storage:vsan",
          "cluster_provider_ref" => "vsphere:vcenter-a:cluster:domain-c7",
          "name" => "vSAN",
          "storage_system_type" => "vsan",
          "health" => "green"
        }
      ],
      "console_targets" => [
        %{
          "target_ref" => "vsphere:vcenter-a:guest:vm-100",
          "target_type" => "guest",
          "protocol" => "vsphere-console",
          "transport" => "framebuffer",
          "credential_purpose" => "console_access",
          "agent_id" => "agent-vcenter-a",
          "capabilities" => ["data", "resize", "close"],
          "metadata" => %{
            "display_name" => "app-01",
            "moid" => "vm-100"
          }
        }
      ]
    }
  end

  defp sensitive_value?(%DateTime{}), do: false

  defp sensitive_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      sensitive_key?(key) or sensitive_value?(nested)
    end)
  end

  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)

  defp sensitive_value?(value) when is_binary(value), do: String.contains?(value, "drop-me")
  defp sensitive_value?(_value), do: false

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    if key == "credential_purpose" do
      false
    else
      Enum.any?(["password", "secret", "token", "credential"], fn part ->
        String.contains?(key, part)
      end)
    end
  end
end
