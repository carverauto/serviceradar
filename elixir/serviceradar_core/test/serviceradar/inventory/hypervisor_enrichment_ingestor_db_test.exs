defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestorDbTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo

  @moduletag :integration

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:hypervisor_enrichment_ingestor_db_test)}
  end

  test "creates placeholder inventory devices for hypervisor assets without network identity", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_ref = "#{provider}:node:pve-placeholder-#{suffix}"
    guest_ref = "#{provider}:guest:pve-placeholder-#{suffix}:vm:132"

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "name" => "pve-placeholder-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "10.10.#{rem(suffix, 200)}.11/24"}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "name" => "vm-placeholder-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 132,
            "status" => "unknown"
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{provider}:guest-nic:pve-placeholder-#{suffix}:vm:132:net0",
            "host_provider_ref" => host_ref,
            "guest_provider_ref" => guest_ref,
            "name" => "net0",
            "mac_address" => "02:00:00:00:#{rem(suffix, 90) + 10}:01",
            "ip_addresses" => ["10.20.#{rem(suffix, 200)}.12/24"],
            "source" => "config"
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    [[host_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_hosts
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, host_ref]
      ).rows

    [[guest_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_guests
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, guest_ref]
      ).rows

    assert String.starts_with?(host_uid, "sr:")
    assert String.starts_with?(guest_uid, "sr:")
    assert host_uid != guest_uid

    assert [[host_uid, "Hypervisor", 99, "10.10.#{rem(suffix, 200)}.11", host_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, d.ip, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [host_uid]
             ).rows

    assert [[guest_uid, "Virtual", 6, "10.20.#{rem(suffix, 200)}.12", guest_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, d.ip, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [guest_uid]
             ).rows
  end

  test "does not let virtual guests claim an agent-managed host UID", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_uid = "sr:agent-managed-hv-parent-#{suffix}"
    guest_ref = "#{provider}:guest:pve-parent-#{suffix}:vm:133"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: host_uid,
          type: "Server",
          type_id: 1,
          name: "agent-managed-parent-#{suffix}",
          hostname: "agent-managed-parent-#{suffix}",
          agent_id: "agent-hv-parent-#{suffix}",
          discovery_sources: ["agent", "sysmon"],
          is_managed: true
        },
        actor: actor
      )
      |> Ash.create()

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "device_uid" => host_uid,
            "name" => "vm-parent-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 133,
            "status" => "running"
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    [[guest_uid]] =
      Repo.query!(
        """
        SELECT device_uid
        FROM platform.virtualization_guests
        WHERE provider = $1 AND provider_ref = $2
        """,
        [provider, guest_ref]
      ).rows

    assert String.starts_with?(guest_uid, "sr:")
    assert guest_uid != host_uid

    assert [[guest_uid, "Virtual", 6, guest_ref]] ==
             Repo.query!(
               """
               SELECT d.uid, d.type, d.type_id, di.identifier_value
               FROM platform.ocsf_devices d
               JOIN platform.device_identifiers di
                 ON di.device_id = d.uid
                AND di.identifier_type = 'integration_id'
               WHERE d.uid = $1
               """,
               [guest_uid]
             ).rows
  end

  test "links guests to existing discovered devices by MAC and backfills IP evidence", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_ref = "#{provider}:node:pve-identity-#{suffix}"
    guest_ref = "#{provider}:guest:pve-identity-#{suffix}:lxc:201"
    existing_uid = "sr:mapper-guest-#{suffix}"
    mac = "02:00:00:44:#{rem(suffix, 90) + 10}:21"
    normalized_mac = IdentityReconciler.normalize_mac(mac)
    ip = "10.44.#{rem(suffix, 200)}.21"
    cidr = "#{ip}/24"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: existing_uid,
          type: "Server",
          type_id: 1,
          name: "mapper-guest-#{suffix}",
          hostname: "mapper-guest-#{suffix}",
          discovery_sources: ["mapper"],
          is_managed: false
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(
        :register,
        %{
          device_id: existing_uid,
          identifier_type: :mac,
          identifier_value: normalized_mac,
          partition: "default",
          source: "mapper"
        },
        actor: actor
      )
      |> Ash.create()

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "name" => "pve-identity-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "10.44.#{rem(suffix, 200)}.10"}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "name" => "lxc-identity-#{suffix}",
            "guest_type" => "container",
            "vmid" => 201,
            "status" => "running"
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{provider}:guest-nic:pve-identity-#{suffix}:lxc:201:eth0",
            "host_provider_ref" => host_ref,
            "guest_provider_ref" => guest_ref,
            "name" => "eth0",
            "mac_address" => mac,
            "ip_addresses" => [cidr],
            "source" => "lxc_interfaces",
            "metadata" => %{"partition" => "default"}
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    assert [[^existing_uid, ^ip]] =
             Repo.query!(
               """
               SELECT uid, ip
               FROM platform.ocsf_devices
               WHERE uid = $1
               """,
               [existing_uid]
             ).rows

    assert [[^existing_uid, ^guest_ref]] =
             Repo.query!(
               """
               SELECT device_uid, provider_ref
               FROM platform.virtualization_guests
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, guest_ref]
             ).rows

    assert [[^existing_uid, "eth0", ^mac, [^cidr], "lxc_interfaces"]] =
             Repo.query!(
               """
               SELECT device_uid, name, mac_address, ip_addresses, source
               FROM platform.virtualization_network_interfaces
               WHERE provider = $1 AND guest_provider_ref = $2
               """,
               [provider, guest_ref]
             ).rows
  end
end
