defmodule ServiceRadar.Inventory.HypervisorEnrichmentIngestorDbTest do
  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.IntegrationIdentity
  alias ServiceRadar.Inventory.ProxmoxEnrichmentIngestor
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Repo
  alias ServiceRadar.Repo.Migrations.ArchiveDisplacedBridgeIdentityAliases

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

  test "links a streamed Proxmox guest batch to a host persisted by the node batch", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    node = "pve-streamed-#{suffix}"
    native_cluster_id = "streamed-#{suffix}"

    source_scope = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "farm01"
    }

    {:ok, host_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        source_scope.integration_id,
        source_scope.controller_id,
        native_cluster_id,
        "node",
        node
      )

    {:ok, guest_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        source_scope.integration_id,
        source_scope.controller_id,
        native_cluster_id,
        "qemu",
        suffix
      )

    host_ref = host_identity.provider_ref
    guest_ref = guest_identity.provider_ref

    {:ok, nic_ref} =
      IntegrationIdentity.proxmox_v3_child_ref(
        host_identity.provider_instance_ref,
        "guest-nic",
        [guest_ref, "020000000001"]
      )

    observed_at = DateTime.utc_now()

    node_payload = %{
      "observed_at" => DateTime.to_iso8601(observed_at),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => native_cluster_id}],
            "nodes" => [
              %{
                "node" => node,
                "status" => "online",
                "ip" => "10.78.#{rem(suffix, 200)}.11"
              }
            ],
            "guests" => []
          }
        ]
      }
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(node_payload, %{},
               actor: actor,
               source_scope: source_scope
             )

    VirtualizationHost
    |> Ash.Changeset.for_create(:create, %{
      provider: "vsphere",
      provider_ref: host_ref,
      name: "wrong-provider-#{node}",
      observed_at: observed_at
    })
    |> Ash.create!(actor: actor)

    guest_payload = %{
      "observed_at" => DateTime.to_iso8601(observed_at),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => native_cluster_id}],
            "nodes" => [],
            "guests" => [
              %{
                "node" => node,
                "type" => "qemu",
                "vmid" => suffix,
                "name" => "vm-streamed-#{suffix}",
                "status" => "running",
                "interfaces" => [
                  %{
                    "name" => "eth0",
                    "mac_address" => "02:00:00:00:00:01",
                    "ip_addresses" => ["10.79.#{rem(suffix, 200)}.12/24"],
                    "source" => "config"
                  }
                ]
              }
            ]
          }
        ]
      }
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(guest_payload, %{},
               actor: actor,
               source_scope: source_scope
             )

    assert [[host_id, ^host_ref, guest_id, ^guest_ref, ^host_ref, ^nic_ref]] =
             Repo.query!(
               """
               SELECT h.id, h.provider_ref, g.id, g.provider_ref, nh.provider_ref, n.provider_ref
               FROM platform.virtualization_hosts h
               JOIN platform.virtualization_guests g ON g.host_id = h.id
               JOIN platform.virtualization_network_interfaces n
                 ON n.host_id = h.id AND n.guest_id = g.id
               JOIN platform.virtualization_hosts nh ON nh.id = n.host_id
               WHERE h.provider = 'proxmox'
                 AND h.provider_ref = $1
                 AND g.provider_ref = $2
                 AND n.provider_ref = $3
               """,
               [host_ref, guest_ref, nic_ref]
             ).rows

    assert is_binary(host_id)
    assert is_binary(guest_id)
  end

  test "a new guest reported with its node gets its own device, not the node's", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    node = "pve-guest-scope-#{suffix}"
    native_cluster_id = "guest-scope-#{suffix}"
    guest_name = "vm-guest-scope-#{suffix}"

    source_scope = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "default"
    }

    node_entry = %{
      "node" => node,
      "status" => "online",
      "ip" => "192.0.2.#{rem(suffix, 200) + 1}"
    }

    payload = fn guests ->
      %{
        "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "details" => %{
          "schema" => "serviceradar.proxmox_enrichment.v1",
          "targets" => [
            %{
              "cluster" => [%{"type" => "cluster", "name" => native_cluster_id}],
              "nodes" => [node_entry],
              "guests" => guests
            }
          ]
        }
      }
    end

    # The node is persisted first, so its integration identity is registered
    # when the guest arrives alongside it.
    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload.([]), %{},
               actor: actor,
               source_scope: source_scope
             )

    guest = %{
      "node" => node,
      "type" => "lxc",
      "vmid" => 100 + rem(suffix, 800),
      "name" => guest_name,
      "status" => "running",
      "interfaces" => [
        %{
          "name" => "eth0",
          "mac_address" => "02:00:00:00:00:02",
          "ip_addresses" => ["198.51.100.#{rem(suffix, 200) + 1}/24"],
          "source" => "config"
        }
      ]
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload.([guest]), %{},
               actor: actor,
               source_scope: source_scope
             )

    assert [[node_uid, guest_uid, guest_hostname]] =
             Repo.query!(
               """
               SELECT h.device_uid, g.device_uid, d.hostname
               FROM platform.virtualization_hosts h
               JOIN platform.virtualization_guests g ON g.host_id = h.id
               JOIN platform.ocsf_devices d ON d.uid = g.device_uid
               WHERE h.provider = 'proxmox' AND h.name = $1 AND g.name = $2
               """,
               [node, guest_name]
             ).rows

    assert is_binary(node_uid)
    refute guest_uid == node_uid
    assert guest_hostname == guest_name
  end

  test "resolves hosts to existing devices by case-insensitive hostname", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_ref = "#{provider}:node:pve-case-#{suffix}"
    existing_uid = "sr:existing-host-case-#{suffix}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: existing_uid,
          type: "Server",
          type_id: 1,
          name: "PVE-Case-#{suffix}",
          hostname: "PVE-Case-#{suffix}",
          discovery_sources: ["mapper"],
          is_managed: false
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
            "name" => "pve-case-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "10.61.#{rem(suffix, 200)}.11"}
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    assert [[^existing_uid]] =
             Repo.query!(
               """
               SELECT device_uid
               FROM platform.virtualization_hosts
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, host_ref]
             ).rows
  end

  test "resolves hosts to existing devices by host NIC MAC identity", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_ref = "#{provider}:node:esx-mac-#{suffix}"
    existing_uid = "sr:existing-host-mac-#{suffix}"
    mac = "02:00:00:66:#{rem(suffix, 90) + 10}:31"
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: existing_uid,
          type: "Server",
          type_id: 1,
          name: "esx-host-mac-#{suffix}",
          hostname: "esx-host-mac-#{suffix}.lab.example",
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
            # Name intentionally does not match the existing device: only the
            # NIC MAC ties the host to it.
            "provider_ref" => host_ref,
            "name" => "esx-mac-#{suffix}",
            "status" => "online",
            "metadata" => %{}
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{provider}:nic:esx-mac-#{suffix}:vmnic0",
            "host_provider_ref" => host_ref,
            "name" => "vmnic0",
            "mac_address" => mac,
            "address" => "10.62.#{rem(suffix, 200)}.11",
            "source" => "host_config"
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    assert [[^existing_uid]] =
             Repo.query!(
               """
               SELECT device_uid
               FROM platform.virtualization_hosts
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, host_ref]
             ).rows

    # No parallel placeholder device was minted for the host.
    assert [[^existing_uid, ^host_ref]] =
             Repo.query!(
               """
               SELECT device_id, identifier_value
               FROM platform.device_identifiers
               WHERE identifier_type = 'integration_id' AND identifier_value = $1
               """,
               [host_ref]
             ).rows
  end

  test "rejects new legacy Proxmox v2 writes", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "proxmox"
    cluster = "farm-#{suffix}"
    node = "pve-legacy-#{suffix}"
    guest_name = "legacy-guest-#{suffix}"
    guest_ref = "#{provider}:guest:#{node}:qemu:132"
    v2_id = "proxmox:v2:#{cluster}:vm:132"

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => "#{provider}:node:#{node}",
            "name" => guest_name,
            "guest_type" => "vm",
            "vmid" => 132,
            "status" => "running",
            "metadata" => %{"integration_id" => v2_id}
          }
        ]
      }
    }

    assert {:error, {:proxmox_v3_identity_required, ^guest_ref}} =
             HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)

    assert [] ==
             Repo.query!(
               """
               SELECT id
               FROM platform.virtualization_guests
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, guest_ref]
             ).rows
  end

  test "does not let virtual guests claim an agent-managed host UID", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv"
    host_uid = "sr:agent-managed-hv-parent-#{suffix}"
    host_ref = "#{provider}:node:pve-parent-#{suffix}"
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
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "device_uid" => host_uid,
            "name" => "pve-parent-#{suffix}",
            "status" => "online",
            "metadata" => %{}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "device_uid" => host_uid,
            "name" => "vm-parent-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 133,
            "status" => "running"
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{provider}:guest-nic:pve-parent-#{suffix}:vm:133:net0",
            "host_provider_ref" => host_ref,
            "guest_provider_ref" => guest_ref,
            "name" => "net0",
            "mac_address" => "02:00:00:00:85:01",
            "ip_addresses" => ["10.66.#{rem(suffix, 200)}.13/24"],
            "source" => "config"
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

  test "binds Proxmox result to server-owned integration identity and ignores supplied UID", %{
    actor: actor
  } do
    suffix = System.unique_integer([:positive])
    provider = "proxmox"
    native_cluster_id = "network-#{suffix}"
    native_node_id = "pve-network-ip-#{suffix}"

    {:ok, host_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        native_cluster_id,
        "node",
        native_node_id
      )

    host_ref = host_identity.provider_ref
    host_uid = "sr:existing-hv-network-ip-#{suffix}"
    unrelated_uid = "sr:unrelated-hv-network-ip-#{suffix}"
    host_ip = "10.55.#{rem(suffix, 200)}.11"

    {:ok, link_local_nic_ref} =
      IntegrationIdentity.proxmox_v3_child_ref(
        host_identity.provider_instance_ref,
        "nic",
        [host_ref, "eno1"]
      )

    {:ok, management_nic_ref} =
      IntegrationIdentity.proxmox_v3_child_ref(
        host_identity.provider_instance_ref,
        "nic",
        [host_ref, "vmbr0"]
      )

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: host_uid,
          type: "Hypervisor",
          type_id: 99,
          name: "pve-network-ip-#{suffix}",
          hostname: "pve-network-ip-#{suffix}",
          discovery_sources: ["mapper"],
          is_managed: false
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _unrelated_device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: unrelated_uid,
          type: "Server",
          type_id: 1,
          name: "unrelated-network-ip-#{suffix}",
          hostname: "unrelated-network-ip-#{suffix}",
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
          device_id: host_uid,
          identifier_type: :integration_id,
          identifier_value: host_ref,
          partition: "default",
          source: "serviceradar"
        },
        actor: actor
      )
      |> Ash.create()

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "hosts" => [
          Map.merge(host_identity, %{
            "device_uid" => unrelated_uid,
            "name" => native_node_id,
            "status" => "online",
            "metadata" => %{"partition" => "default"}
          })
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => link_local_nic_ref,
            "host_provider_ref" => host_ref,
            "name" => "eno1",
            "address" => "169.254.10.1",
            "source" => "host_config",
            "metadata" => %{"partition" => "default"}
          },
          %{
            "provider_ref" => management_nic_ref,
            "host_provider_ref" => host_ref,
            "name" => "vmbr0",
            "address" => host_ip,
            "cidr" => "#{host_ip}/24",
            "source" => "host_config",
            "metadata" => %{"partition" => "default"}
          }
        ]
      }
    }

    assert :ok =
             HypervisorEnrichmentIngestor.ingest(payload, %{},
               actor: actor,
               source_scope: %{
                 integration_id: host_identity.integration_id,
                 controller_id: host_identity.controller_id,
                 partition_id: "default"
               }
             )

    assert [[^host_uid, ^host_ip]] =
             Repo.query!(
               """
               SELECT uid, ip
               FROM platform.ocsf_devices
               WHERE uid = $1
               """,
               [host_uid]
             ).rows

    assert [[^unrelated_uid, nil]] =
             Repo.query!(
               "SELECT uid, ip FROM platform.ocsf_devices WHERE uid = $1",
               [unrelated_uid]
             ).rows

    assert [[true, "hypervisor_enrichment", "pve-api"]] =
             Repo.query!(
               """
               SELECT
                 metadata->>'proxmox_candidate' = 'true',
                 metadata->>'proxmox_candidate_source',
                 metadata->>'proxmox_candidate_service'
               FROM platform.ocsf_devices
               WHERE uid = $1
               """,
               [host_uid]
             ).rows

    assert [[^host_uid, ^host_ip]] =
             Repo.query!(
               """
               SELECT device_uid, metadata->>'ip'
               FROM platform.virtualization_hosts
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, host_ref]
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

  test "failed identifier or device lookups do not mint placeholder devices", %{actor: actor} do
    suffix = System.unique_integer([:positive])
    provider = "testhv-fail"
    host_ref = "#{provider}:node:pve-fail-#{suffix}"
    guest_ref = "#{provider}:guest:pve-fail-#{suffix}:vm:999"

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => provider,
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "name" => "pve-fail-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "192.0.2.#{rem(suffix, 200) + 10}/24"}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "name" => "vm-fail-#{suffix}",
            "guest_type" => "vm",
            "vmid" => 999,
            "status" => "online"
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{provider}:guest-nic:pve-fail-#{suffix}:vm:999:net0",
            "host_provider_ref" => host_ref,
            "guest_provider_ref" => guest_ref,
            "name" => "net0",
            "mac_address" => "02:00:00:00:#{rem(suffix, 90) + 10}:99",
            "ip_addresses" => ["192.0.2.#{rem(suffix, 200) + 20}/24"],
            "source" => "config"
          }
        ]
      }
    }

    # An unshared process cannot checkout a connection from the test sandbox,
    # replicating a DB query failure / timeout.
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:ingest_result, HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: actor)}
      )
    end)

    assert_receive {:ingest_result, result}, 30_000
    assert {:error, _reason} = result

    # Assert no device or virtualization record was created
    assert [] =
             Repo.query!(
               """
               SELECT uid FROM platform.ocsf_devices
               WHERE hostname IN ($1, $2)
               """,
               ["pve-fail-#{suffix}", "vm-fail-#{suffix}"]
             ).rows

    assert [] =
             Repo.query!(
               """
               SELECT device_uid FROM platform.virtualization_hosts
               WHERE provider = $1 AND provider_ref = $2
               """,
               [provider, host_ref]
             ).rows
  end

  test "merges pre-existing IP-less Proxmox guest, swept IP holder, and AWX host into one device and retires legacy proxmox:vm:* records",
       %{actor: actor} do
    suffix = System.unique_integer([:positive])
    node_name = "pve-merge-#{suffix}"
    native_cluster_id = "cluster-merge-#{suffix}"
    vmid = 500 + rem(suffix, 400)

    source_scope = %{
      integration_id: Ecto.UUID.generate(),
      controller_id: Ecto.UUID.generate(),
      partition_id: "default"
    }

    {:ok, guest_identity} =
      IntegrationIdentity.proxmox_v3_fields(
        source_scope.integration_id,
        source_scope.controller_id,
        native_cluster_id,
        "qemu",
        vmid
      )

    guest_ref = guest_identity.provider_ref
    guest_uid = "sr:" <> Ecto.UUID.generate()
    swept_uid = "sr:" <> Ecto.UUID.generate()
    awx_uid = "sr:" <> Ecto.UUID.generate()
    legacy_uid = "sr:" <> Ecto.UUID.generate()
    legacy_integration_id = "proxmox:vm:qemu/#{vmid}"

    octet4 = rem(suffix, 200) + 10
    guest_ip = "198.51.100.#{rem(octet4, 240) + 10}"
    guest_cidr = "#{guest_ip}/24"
    mac_hex = suffix |> rem(250) |> Integer.to_string(16) |> String.pad_leading(2, "0")
    guest_mac = "02:AA:BB:CC:#{String.upcase(mac_hex)}:11"
    normalized_mac = "02AABBCC#{String.upcase(mac_hex)}11"

    # 1. Pre-existing IP-less Proxmox guest device
    {:ok, _} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: guest_uid,
          type: "Virtual",
          type_id: 1,
          name: "vm-#{vmid}",
          hostname: "vm-#{vmid}",
          discovery_sources: ["proxmox"],
          metadata: %{
            "integration_id" => guest_ref,
            "hypervisor_provider" => "proxmox",
            "hypervisor_guest_ref" => guest_ref
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(
        :register,
        %{
          device_id: guest_uid,
          identifier_type: :integration_id,
          identifier_value: guest_ref,
          partition: "default",
          source: "proxmox"
        },
        actor: actor
      )
      |> Ash.create()

    # 2. Live swept device holding the guest's IP (without a MAC identifier yet)
    {:ok, _} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: swept_uid,
          ip: guest_ip,
          type: "Server",
          type_id: 1,
          name: "swept-#{vmid}",
          hostname: "swept-#{vmid}",
          discovery_sources: ["sweep", "mapper"]
        },
        actor: actor
      )
      |> Ash.create()

    # 3. Live IP-less AWX host referencing the same Proxmox (node, vmid) and ansible_host
    awx_integration_id = "awx:v2:ctrl-#{suffix}:host:#{vmid}"

    {:ok, _} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: awx_uid,
          type: "Server",
          type_id: 1,
          name: "awx-#{vmid}",
          hostname: "awx-#{vmid}",
          discovery_sources: ["awx"],
          metadata: %{
            "integration_id" => awx_integration_id,
            "awx" => %{
              "ansible_host" => guest_ip,
              "proxmox_vmid" => Integer.to_string(vmid),
              "proxmox_node" => node_name
            }
          }
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(
        :register,
        %{
          device_id: awx_uid,
          identifier_type: :integration_id,
          identifier_value: awx_integration_id,
          partition: "default",
          source: "awx"
        },
        actor: actor
      )
      |> Ash.create()

    # 4. Legacy proxmox:vm:qemu/<vmid> device record
    {:ok, _} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: legacy_uid,
          type: "Virtual",
          type_id: 1,
          name: "qemu/#{vmid}",
          hostname: "qemu/#{vmid}",
          discovery_sources: ["proxmox"]
        },
        actor: actor
      )
      |> Ash.create()

    Repo.query!(
      """
      INSERT INTO platform.device_identifiers
        (device_id, identifier_type, identifier_value, partition, confidence, source, first_seen, last_seen, verified, metadata)
      VALUES ($1, 'integration_id', $2, 'default', 'strong', 'proxmox', NOW(), NOW(), false, '{}'::jsonb)
      """,
      [legacy_uid, legacy_integration_id]
    )

    payload = %{
      "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "details" => %{
        "schema" => "serviceradar.proxmox_enrichment.v1",
        "targets" => [
          %{
            "cluster" => [%{"type" => "cluster", "name" => native_cluster_id}],
            "nodes" => [
              %{
                "node" => node_name,
                "status" => "online",
                "ip" => "192.0.2.#{rem(octet4, 200) + 1}"
              }
            ],
            "guests" => [
              %{
                "node" => node_name,
                "type" => "qemu",
                "vmid" => vmid,
                "name" => "vm-#{vmid}",
                "status" => "running",
                "interfaces" => [
                  %{
                    "name" => "eth0",
                    "mac_address" => guest_mac,
                    "ip_addresses" => [guest_cidr],
                    "source" => "config+agent"
                  }
                ]
              }
            ]
          }
        ]
      }
    }

    assert :ok =
             ProxmoxEnrichmentIngestor.ingest(payload, %{},
               actor: actor,
               source_scope: source_scope
             )

    # Guest device now owns the IP, MAC, and AWX integration_id; swept and AWX duplicates are merged
    assert [[^guest_uid, ^guest_ip, ^normalized_mac, nil]] =
             Repo.query!(
               """
               SELECT uid, ip, mac, deleted_at
               FROM platform.ocsf_devices
               WHERE uid = $1
               """,
               [guest_uid]
             ).rows

    assert [[swept_deleted_at]] =
             Repo.query!(
               "SELECT deleted_at FROM platform.ocsf_devices WHERE uid = $1",
               [swept_uid]
             ).rows

    assert swept_deleted_at

    assert [[awx_deleted_at]] =
             Repo.query!(
               "SELECT deleted_at FROM platform.ocsf_devices WHERE uid = $1",
               [awx_uid]
             ).rows

    assert awx_deleted_at

    assert [[^guest_uid]] =
             Repo.query!(
               """
               SELECT device_id
               FROM platform.device_identifiers
               WHERE identifier_type = 'mac' AND identifier_value = $1 AND partition = 'default'
               """,
               [normalized_mac]
             ).rows

    # Legacy proxmox:vm:qemu/<vmid> record is retired through source retirement
    assert [[^legacy_uid, "source_absent"]] =
             Repo.query!(
               """
               SELECT device_id, archive_reason
               FROM platform.device_identifier_archive
               WHERE device_id = $1 AND identifier_value = $2
               """,
               [legacy_uid, legacy_integration_id]
             ).rows

    assert [[legacy_retired_at, "source_retired"]] =
             Repo.query!(
               """
               SELECT source_retired_at, metadata->>'identity_state'
               FROM platform.ocsf_devices
               WHERE uid = $1
               """,
               [legacy_uid]
             ).rows

    assert legacy_retired_at
  end

  test "ArchiveDisplacedBridgeIdentityAliases archives only non-config host-internal replaced_primary_address aliases and is idempotent",
       %{actor: actor} do
    if !Code.ensure_loaded?(ArchiveDisplacedBridgeIdentityAliases) do
      Code.require_file(
        Path.expand(
          "../../../priv/repo/migrations/20261025203100_archive_displaced_bridge_identity_aliases.exs",
          __DIR__
        )
      )
    end

    suffix = System.unique_integer([:positive])
    octet3 = rem(suffix, 200) + 10
    octet4 = rem(div(suffix, 200), 200) + 10
    vmid = rem(suffix, 8000) + 1000
    guest_uid = "sr:guest-bridge-repair-#{suffix}"
    primary_ip = "198.51.100.#{octet4}"
    bridge_ip = "192.0.2.#{octet3}"
    config_bridge_ip = "203.0.113.#{octet3}"
    secondary_lan_ip = "198.51.100.#{rem(octet4 + 1, 250) + 1}"

    guest_mac =
      "AA:BB:CC:DD:#{octet3 |> Integer.to_string(16) |> String.pad_leading(2, "0")}:#{octet4 |> Integer.to_string(16) |> String.pad_leading(2, "0")}"

    {:ok, host} =
      VirtualizationHost
      |> Ash.Changeset.for_create(
        :create,
        %{
          provider: "testhv",
          provider_ref: "testhv:node:pve-bridge-repair-#{suffix}",
          name: "pve-bridge-repair-#{suffix}"
        },
        actor: actor
      )
      |> Ash.create()

    {:ok, _} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: guest_uid,
          ip: primary_ip,
          name: "vm-#{vmid}",
          hostname: "vm-#{vmid}"
        },
        actor: actor
      )
      |> Ash.create()

    now = DateTime.truncate(DateTime.utc_now(), :second)

    # Insert three replaced_primary_address aliases:
    # 1. bridge_ip on non-config docker0 -> MUST be archived
    # 2. config_bridge_ip on config+agent br-lan0 -> MUST remain detected (config-backed)
    # 3. secondary_lan_ip on eth1 -> MUST remain detected (non-host-internal interface)
    for ip <- [bridge_ip, config_bridge_ip, secondary_lan_ip] do
      Repo.query!(
        """
        INSERT INTO platform.device_alias_states
          (id, device_id, partition, alias_type, alias_value, state, first_seen_at, last_seen_at, sighting_count, metadata, inserted_at, updated_at)
        VALUES ($1, $2, 'default', 'ip', $3, 'detected', $4, $4, 1, '{"source":"replaced_primary_address"}'::jsonb, $4, $4)
        """,
        [Ecto.UUID.bingenerate(), guest_uid, ip, now]
      )
    end

    for {if_name, source, ip} <- [
          {"docker0", "agent", bridge_ip},
          {"br-lan0", "config+agent", config_bridge_ip},
          {"eth1", "agent", secondary_lan_ip}
        ] do
      Repo.query!(
        """
        INSERT INTO platform.virtualization_network_interfaces
          (id, provider, provider_ref, host_id, device_uid, name, source, mac_address, address, cidr, ip_addresses, exists, metadata, observed_at, inserted_at, updated_at)
        VALUES ($1, 'testhv', $2, $3, $4, $5, $6, $7, $8, $9, $10, true, '{}'::jsonb, $11, $11, $11)
        """,
        [
          Ecto.UUID.bingenerate(),
          "testhv:guest-nic:#{suffix}:#{if_name}",
          Ecto.UUID.dump!(host.id),
          guest_uid,
          if_name,
          source,
          guest_mac,
          ip,
          "#{ip}/24",
          ["#{ip}/24"],
          now
        ]
      )
    end

    repair_sql = apply(ArchiveDisplacedBridgeIdentityAliases, :repair_sql, ["platform"])

    assert %{num_rows: 1} = Repo.query!(repair_sql)

    assert [
             [^bridge_ip, "archived"],
             [^secondary_lan_ip, "detected"],
             [^config_bridge_ip, "detected"]
           ] =
             Repo.query!(
               """
               SELECT alias_value, state
               FROM platform.device_alias_states
               WHERE device_id = $1
               ORDER BY state ASC, alias_value ASC
               """,
               [guest_uid]
             ).rows

    # Idempotent second run touches zero rows
    assert %{num_rows: 0} = Repo.query!(repair_sql)
  end
end
