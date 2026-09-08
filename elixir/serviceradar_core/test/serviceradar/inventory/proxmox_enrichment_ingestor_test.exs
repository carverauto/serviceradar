defmodule ServiceRadar.Inventory.ProxmoxEnrichmentIngestorTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor

  @observed_at ~U[2026-05-06 16:45:00Z]
  @farm_scope %{
    integration_id: "11111111-1111-4111-8111-111111111111",
    controller_id: "22222222-2222-4222-8222-222222222222",
    partition_id: "farm01"
  }
  @tonka_scope %{
    integration_id: "33333333-3333-4333-8333-333333333333",
    controller_id: "44444444-4444-4444-8444-444444444444",
    partition_id: "tonka01"
  }

  test "mints v3 refs only from a trusted source scope" do
    parent = self()
    payload = payload_with_details(details_fixture(), @observed_at)

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload, %{},
               source_scope: @farm_scope,
               persist: fn records ->
                 send(parent, {:v3_records, records})
                 :ok
               end
             )

    assert_receive {:v3_records, records}

    instance_ref =
      "proxmox:v3:#{@farm_scope.integration_id}:#{@farm_scope.controller_id}:lab"

    assert [cluster] = records.clusters
    assert cluster.provider_instance_ref == instance_ref
    assert cluster.provider_ref == "#{instance_ref}:cluster:lab"
    assert cluster.identity_version == 3
    assert cluster.integration_id == @farm_scope.integration_id
    assert cluster.controller_id == @farm_scope.controller_id
    assert cluster.metadata["partition"] == @farm_scope.partition_id
    assert cluster.legacy_provider_refs == ["proxmox:cluster:lab"]

    host_a = find_record!(records.hosts, "#{instance_ref}:node:pve-a")
    assert host_a.cluster_provider_ref == cluster.provider_ref
    assert host_a.object_kind == "node"
    assert host_a.native_object_id == "pve-a"
    assert host_a.metadata["integration_id"] == host_a.provider_ref
    assert host_a.legacy_provider_refs == ["proxmox:node:pve-a"]
    # metadata.device_id is result-owned. Even with a matching hostname it
    # cannot choose an existing device for an authoritative v3 record.
    assert is_nil(host_a.device_uid)

    host_b = find_record!(records.hosts, "#{instance_ref}:node:pve-b")
    assert is_nil(host_b.device_uid)

    assert [guest] = records.guests
    assert guest.provider_ref == "#{instance_ref}:qemu:100"
    assert guest.host_provider_ref == host_a.provider_ref
    assert guest.object_kind == "qemu"
    assert guest.native_object_id == "100"
    assert guest.legacy_provider_refs == ["proxmox:guest:pve-a:qemu:100"]
    assert is_nil(guest.device_uid)

    guest_nic =
      Enum.find(records.network_interfaces, &(&1.guest_provider_ref == guest.provider_ref))

    assert is_nil(guest_nic.device_uid)

    assert Enum.all?(
             records.datastores ++
               records.host_disks ++
               records.network_interfaces ++
               records.storage_systems,
             &String.starts_with?(&1.provider_ref, instance_ref <> ":")
           )

    # Values in the untrusted result cannot create a v3 scope on their own.
    untrusted_details =
      details_fixture()
      |> put_in(
        ["targets", Access.at(0), "metadata", "source_integration_id"],
        @tonka_scope.integration_id
      )
      |> put_in(
        ["targets", Access.at(0), "metadata", "source_controller_id"],
        @tonka_scope.controller_id
      )

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(
               payload_with_details(untrusted_details, @observed_at),
               %{},
               persist: fn legacy_records ->
                 send(parent, {:legacy_records, legacy_records})
                 :ok
               end
             )

    assert_receive {:legacy_records, legacy_records}
    assert [legacy_cluster] = legacy_records.clusters
    assert legacy_cluster.provider_ref == "proxmox:cluster:lab"
    refute Map.has_key?(legacy_cluster, :identity_version)
  end

  test "keeps farm01 and tonka01 records distinct with identical native inventory" do
    parent = self()
    payload = payload_with_details(details_fixture(), @observed_at)

    for {label, scope} <- [farm: @farm_scope, tonka: @tonka_scope] do
      assert :ok =
               ProxmoxEnrichmentIngestor.ingest(payload, %{},
                 source_scope: scope,
                 persist: fn records ->
                   send(parent, {label, records})
                   :ok
                 end
               )
    end

    assert_receive {:farm, farm}
    assert_receive {:tonka, tonka}

    for key <- [:clusters, :hosts, :guests, :datastores, :host_disks, :network_interfaces] do
      farm_refs = farm |> Map.fetch!(key) |> MapSet.new(& &1.provider_ref)
      tonka_refs = tonka |> Map.fetch!(key) |> MapSet.new(& &1.provider_ref)
      assert MapSet.disjoint?(farm_refs, tonka_refs)
    end

    assert hd(farm.guests).native_object_id == hd(tonka.guests).native_object_id
    assert hd(farm.guests).host_provider_ref != hd(tonka.guests).host_provider_ref
    assert hd(farm.guests).metadata["partition"] == "farm01"
    assert hd(tonka.guests).metadata["partition"] == "tonka01"
  end

  test "advertises support for typed Proxmox enrichment details" do
    payload = %{
      "details" =>
        Jason.encode!(%{
          "schema" => "serviceradar.proxmox_enrichment.v1",
          "targets" => []
        })
    }

    assert ProxmoxEnrichmentIngestor.supports?(payload, %{})
    assert ProxmoxEnrichmentIngestor.supports?([%{"status" => "OK"}, payload], %{})
    refute ProxmoxEnrichmentIngestor.supports?(%{"details" => %{"schema" => "unknown"}}, %{})
    refute ProxmoxEnrichmentIngestor.supports?(%{"status" => "OK"}, %{})
  end

  test "maps Proxmox details into provider-neutral virtualization records without secrets" do
    parent = self()

    payload = %{
      "observed_at" => DateTime.to_iso8601(@observed_at),
      "details" => Jason.encode!(details_fixture())
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload, %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    assert [cluster] = records.clusters
    assert cluster.provider == "proxmox"
    assert cluster.provider_ref == "proxmox:cluster:lab"
    assert cluster.status == "quorate"

    assert length(records.hosts) == 2
    host_a = find_record!(records.hosts, "proxmox:node:pve-a")
    host_b = find_record!(records.hosts, "proxmox:node:pve-b")
    assert host_a.device_uid == "sr:device:pve-a"
    assert host_a.cluster_provider_ref == "proxmox:cluster:lab"
    assert host_a.cpu_ratio == 0.25
    assert host_a.metadata["ip"] == "10.10.0.11"
    assert host_a.metadata["cluster_node"]["ip"] == "10.10.0.11"
    assert host_a.metadata["integration_id"] == "proxmox:v2:lab:node:pve-a"
    assert host_b.device_uid == "proxmox:pve:pve-b"
    assert host_b.metadata["ip"] == "10.10.0.12"
    assert host_b.metadata["integration_id"] == "proxmox:v2:lab:node:pve-b"

    assert [guest] = records.guests
    assert guest.provider_ref == "proxmox:guest:pve-a:qemu:100"
    assert guest.host_provider_ref == "proxmox:node:pve-a"
    assert guest.device_uid == "proxmox:qemu:100"
    assert guest.guest_type == "vm"
    assert guest.vmid == 100
    assert guest.metadata["integration_id"] == "proxmox:v2:lab:vm:100"

    assert [datastore] = records.datastores
    assert datastore.provider_ref == "proxmox:datastore:pve-a:local-zfs"
    assert datastore.host_provider_ref == "proxmox:node:pve-a"
    assert datastore.active == true
    assert datastore.shared == false
    assert datastore.used_bytes == 8192

    assert [disk] = records.host_disks
    assert disk.provider_ref == "proxmox:disk:pve-a:/dev/sda"
    assert disk.health == "PASSED"
    refute Map.has_key?(disk.metadata, "token")

    assert length(records.network_interfaces) == 2
    nic = find_record!(records.network_interfaces, "proxmox:nic:pve-a:vmbr0")
    assert nic.active == false
    assert nic.exists == true
    assert nic.mac_address == "00AABBCCDDEE"
    assert nic.ip_addresses == ["10.10.0.11/24", "10.10.0.11"]

    guest_nic =
      Enum.find(
        records.network_interfaces,
        &(&1.guest_provider_ref == "proxmox:guest:pve-a:qemu:100")
      ) ||
        flunk("missing guest NIC record")

    assert guest_nic.host_provider_ref == "proxmox:node:pve-a"
    # Canonical separator-free 12-hex MAC (IdentityReconciler.normalize_mac)
    assert guest_nic.mac_address == "001122334455"
    assert guest_nic.ip_addresses == ["192.168.2.50/24"]
    assert guest_nic.address == "192.168.2.50"
    assert guest_nic.bridge_ports == "vmbr0"
    assert guest_nic.source == "config,guest_agent"

    assert [ceph] = records.storage_systems
    assert ceph.provider_ref == "proxmox:ceph:pve-a"
    assert ceph.health == "HEALTH_WARN"

    refute sensitive_value?(records)
  end

  test "merges duplicate Proxmox identities and keeps the newest enrichment" do
    parent = self()
    stale_at = DateTime.add(@observed_at, -300, :second)
    fresh_at = DateTime.add(@observed_at, 300, :second)

    stale_details =
      details_fixture()
      |> put_in(["targets", Access.at(0), "nodes", Access.at(0), "cpu"], 0.05)
      |> put_in(["targets", Access.at(0), "guests", Access.at(0), "status"], "stopped")

    fresh_details =
      details_fixture()
      |> put_in(["targets", Access.at(0), "nodes", Access.at(0), "cpu"], 0.75)
      |> put_in(["targets", Access.at(0), "guests", Access.at(0), "status"], "running")

    stale_payload = payload_with_details(stale_details, stale_at)
    fresh_payload = payload_with_details(fresh_details, fresh_at)

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(
               [stale_payload, %{"status" => "OK"}, fresh_payload],
               %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    assert Enum.count(records.hosts, &(&1.provider_ref == "proxmox:node:pve-a")) == 1
    assert Enum.count(records.guests, &(&1.provider_ref == "proxmox:guest:pve-a:qemu:100")) == 1

    assert find_record!(records.hosts, "proxmox:node:pve-a").cpu_ratio == 0.75

    guest = find_record!(records.guests, "proxmox:guest:pve-a:qemu:100")
    assert guest.status == "running"
    assert guest.observed_at == fresh_at
  end

  test "uses the node name as v2 scope for standalone (non-clustered) nodes" do
    parent = self()

    details =
      put_in(details_fixture(), ["targets", Access.at(0), "cluster"], [
        %{"type" => "node", "name" => "pve-a", "ip" => "10.10.0.11", "online" => 1}
      ])

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload_with_details(details, @observed_at), %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    assert records.clusters == []

    host_a = find_record!(records.hosts, "proxmox:node:pve-a")
    assert host_a.metadata["integration_id"] == "proxmox:v2:pve-a:node:pve-a"

    guest = find_record!(records.guests, "proxmox:guest:pve-a:qemu:100")
    assert guest.metadata["integration_id"] == "proxmox:v2:pve-a:vm:100"
  end

  test "does not mint v2 ids when the cluster status fetch failed" do
    parent = self()

    details =
      details_fixture()
      |> put_in(["targets", Access.at(0), "cluster"], [])
      |> put_in(
        ["targets", Access.at(0), "warnings"],
        %{"cluster_status" => "503 service unavailable"}
      )

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload_with_details(details, @observed_at), %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    host_a = find_record!(records.hosts, "proxmox:node:pve-a")
    refute Map.has_key?(host_a.metadata, "integration_id")

    guest = find_record!(records.guests, "proxmox:guest:pve-a:qemu:100")
    refute Map.has_key?(guest.metadata, "integration_id")
  end

  test "drops invalid guest NIC MACs instead of emitting malformed values" do
    parent = self()

    details =
      put_in(
        details_fixture(),
        ["targets", Access.at(0), "guests", Access.at(0), "interfaces", Access.at(0)],
        %{
          "name" => "eth0",
          "mac_address" => "not-a-mac",
          "ip_addresses" => ["192.168.2.50/24"],
          "source" => "config"
        }
      )

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload_with_details(details, @observed_at), %{},
               persist: fn records ->
                 send(parent, {:records, records})
                 :ok
               end
             )

    assert_receive {:records, records}

    guest_nic =
      Enum.find(
        records.network_interfaces,
        &(&1.guest_provider_ref == "proxmox:guest:pve-a:qemu:100")
      ) ||
        flunk("missing guest NIC record")

    assert guest_nic.mac_address == nil
    assert guest_nic.ip_addresses == ["192.168.2.50/24"]
  end

  defp details_fixture do
    %{
      "schema" => "serviceradar.proxmox_enrichment.v1",
      "targets" => [
        %{
          "base_url" => "https://pve-a.example:8006",
          "version" => %{"version" => "8.3.2"},
          "metadata" => %{
            "device_id" => "sr:device:pve-a",
            "hostname" => "pve-a.example"
          },
          "cluster" => [
            %{"type" => "cluster", "name" => "lab", "quorate" => 1},
            %{"type" => "node", "name" => "pve-a", "ip" => "10.10.0.11", "online" => 1},
            %{"type" => "node", "id" => "node/pve-b", "ip" => "10.10.0.12", "online" => 1}
          ],
          "nodes" => [
            %{
              "node" => "pve-a",
              "status" => "online",
              "cpu" => 0.25,
              "mem" => 1024,
              "maxmem" => 4096,
              "uptime" => 3600,
              "storage" => [
                %{
                  "storage" => "local-zfs",
                  "type" => "zfspool",
                  "active" => 1,
                  "enabled" => 1,
                  "shared" => 0,
                  "used" => 8192,
                  "total" => 16_384
                }
              ],
              "network" => [
                %{
                  "iface" => "vmbr0",
                  "type" => "bridge",
                  "active" => false,
                  "exists" => 1,
                  "mac_address" => "00:aa:bb:cc:dd:ee",
                  "address" => "10.10.0.11",
                  "cidr" => "10.10.0.11/24",
                  "bridge-ports" => "eno1"
                }
              ],
              "disks" => [
                %{
                  "devpath" => "/dev/sda",
                  "type" => "ssd",
                  "model" => "SSD",
                  "health" => "PASSED",
                  "size" => 1024,
                  "token" => "drop-me"
                }
              ],
              "ceph" => %{
                "health" => "HEALTH_WARN",
                "status" => %{"secret" => "drop-me"}
              }
            },
            %{"node" => "pve-b", "status" => "online"}
          ],
          "guests" => [
            %{
              "node" => "pve-a",
              "type" => "qemu",
              "vmid" => 100,
              "id" => "qemu/100",
              "name" => "vm-100",
              "status" => "running",
              "cpu" => 0.1,
              "mem" => 512,
              "maxmem" => 2048,
              "disk" => 1024,
              "maxdisk" => 4096,
              "config" => %{
                "api_token" => "drop-me",
                "args" => "header PVEAPIToken=secret"
              },
              "interfaces" => [
                %{
                  "name" => "eth0",
                  "model" => "virtio",
                  "mac_address" => "00:11:22:33:44:55",
                  "ip_addresses" => ["192.168.2.50/24"],
                  "bridge" => "vmbr0",
                  "source" => "config,guest_agent",
                  "metadata" => %{"api_token" => "drop-me"}
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp payload_with_details(details, observed_at) do
    %{
      "observed_at" => DateTime.to_iso8601(observed_at),
      "details" => Jason.encode!(details)
    }
  end

  defp find_record!(records, provider_ref) do
    Enum.find(records, &(&1.provider_ref == provider_ref)) ||
      flunk("missing record #{provider_ref}")
  end

  defp sensitive_value?(%DateTime{}), do: false

  defp sensitive_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, nested} ->
      sensitive_key?(key) or sensitive_value?(nested)
    end)
  end

  defp sensitive_value?(value) when is_list(value), do: Enum.any?(value, &sensitive_value?/1)

  defp sensitive_value?(value) when is_binary(value) do
    String.contains?(value, "drop-me") or String.contains?(value, "PVEAPIToken=")
  end

  defp sensitive_value?(_value), do: false

  defp sensitive_key?(key) do
    key
    |> to_string()
    |> String.downcase()
    |> then(
      &Enum.any?(["password", "secret", "token", "credential", "apikey", "api_key"], fn part ->
        String.contains?(&1, part)
      end)
    )
  end
end
