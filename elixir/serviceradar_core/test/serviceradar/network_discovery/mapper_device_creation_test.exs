defmodule ServiceRadar.NetworkDiscovery.MapperDeviceCreationTest do
  @moduledoc """
  Integration tests for mapper device creation when no existing device
  matches the polled IP address.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.Identity.InterfaceMacs
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.Interface
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:mapper_device_creation_test)
    {:ok, actor: actor}
  end

  test "DIRE generates deterministic sr: UUID for mapper-discovered device", %{actor: _actor} do
    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: "AABBCCDDEEFF",
      ip: "192.168.99.1",
      partition: "default"
    }

    device_uid = IdentityReconciler.generate_deterministic_device_id(ids)

    # Should be a proper sr: UUID
    assert String.starts_with?(device_uid, "sr:")

    # Should be deterministic — same input produces same output
    device_uid_2 = IdentityReconciler.generate_deterministic_device_id(ids)
    assert device_uid == device_uid_2
  end

  test "DIRE generates different UUIDs for different IPs with no MAC", %{actor: _actor} do
    ids_a = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: "192.168.99.10",
      partition: "default"
    }

    ids_b = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: "192.168.99.11",
      partition: "default"
    }

    uid_a = IdentityReconciler.generate_deterministic_device_id(ids_a)
    uid_b = IdentityReconciler.generate_deterministic_device_id(ids_b)

    assert uid_a != uid_b
  end

  test "mapper-created device gets correct discovery_sources", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    device_uid = "sr:" <> Ecto.UUID.generate()
    ip = unique_test_ip(198, 18, 150, uniq)

    attrs = %{
      uid: device_uid,
      ip: ip,
      discovery_sources: ["mapper"]
    }

    assert {:ok, device} =
             Device
             |> Ash.Changeset.for_create(:create, attrs)
             |> Ash.create(actor: actor)

    assert device.uid == device_uid
    assert device.ip == ip
    assert device.discovery_sources == ["mapper"]
    assert IdentityReconciler.serviceradar_uuid?(device.uid)
  end

  test "mapper does not create duplicate device for existing IP", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 18, uniq)
    existing_uid = "sr:" <> Ecto.UUID.generate()

    # Create an existing device at this IP
    {:ok, existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: existing_uid, ip: ip})
      |> Ash.create(actor: actor)

    # Verify lookup finds the existing device
    query = Ash.Query.for_read(Device, :by_ip, %{ip: ip})

    {:ok, devices} = Ash.read(query, actor: actor)

    refute Enum.empty?(devices)
    assert Enum.any?(devices, &(&1.uid == existing.uid))
  end

  test "device can be created with management_device_id", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    parent_uid = "sr:" <> Ecto.UUID.generate()
    child_uid = "sr:" <> Ecto.UUID.generate()
    parent_ip = unique_test_ip(192, 168, uniq)
    child_ip = unique_test_ip(203, 0, 113, uniq + 1)

    # Create parent device
    {:ok, _parent} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: parent_uid, ip: parent_ip})
      |> Ash.create(actor: actor)

    # Create child device with management_device_id pointing to parent
    {:ok, child} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: child_uid,
        ip: child_ip,
        management_device_id: parent_uid,
        discovery_sources: ["mapper"]
      })
      |> Ash.create(actor: actor)

    assert child.management_device_id == parent_uid
    assert child.ip == child_ip
  end

  test "device can be created without management_device_id", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    device_uid = "sr:" <> Ecto.UUID.generate()
    ip = unique_test_ip(198, 19, uniq)

    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: device_uid,
        ip: ip,
        discovery_sources: ["mapper"]
      })
      |> Ash.create(actor: actor)

    assert device.management_device_id == nil
    assert device.ip == ip
  end

  test "mapper device UID is stable for same IP across reordered interface MAC payloads", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 18, 200, uniq)
    mac_a = unique_global_test_mac(uniq)
    mac_b = unique_global_test_mac(uniq + 1)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload_a =
      Jason.encode!([
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac_a,
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 2,
          "if_name" => "eth1",
          "if_phys_address" => mac_b,
          "timestamp" => ts
        }
      ])

    payload_b =
      Jason.encode!([
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 2,
          "if_name" => "eth1",
          "if_phys_address" => mac_b,
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac_a,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload_a, %{})

    devices_after_first = wait_for_devices_by_ip(actor, ip)

    assert length(devices_after_first) == 1
    first_uid = hd(devices_after_first).uid
    assert hd(devices_after_first).metadata["identity_state"] == "provisional"
    assert hd(devices_after_first).metadata["identity_source"] == "mapper_primary_mac_seed"

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload_b, %{})

    devices_after_second = wait_for_devices_by_ip(actor, ip)

    assert length(devices_after_second) == 1
    assert hd(devices_after_second).uid == first_uid
  end

  test "VRRP interface MAC cannot seed a first-sighting mapper device", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 18, 210, uniq)
    vrrp_mac = "E2:44:AC:EB:E7:44"
    normalized_vrrp_mac = IdentityReconciler.normalize_mac(vrrp_mac)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    expected_uid =
      IdentityReconciler.generate_deterministic_device_id(%{
        agent_id: nil,
        armis_id: nil,
        integration_id: nil,
        netbox_id: nil,
        mac: nil,
        ip: ip,
        partition: "default"
      })

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 2,
          "if_name" => "vrrp10",
          "if_descr" => "vrrp10",
          "if_type" => 6,
          "if_phys_address" => vrrp_mac,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    assert [device] = wait_for_devices_by_ip(actor, ip)
    assert device.uid == expected_uid
    assert device.mac == nil
    assert device.metadata["identity_source"] == "mapper_ip_seed"

    identifier_query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :mac,
        identifier_value: normalized_vrrp_mac,
        partition: "default"
      })

    assert {:ok, []} = Ash.read(identifier_query, actor: actor)

    assert {:ok, interfaces} =
             Interface
             |> Ash.Query.filter(device_id == ^device.uid)
             |> Ash.read(actor: actor)

    assert Enum.any?(interfaces, &(&1.if_name == "vrrp10"))
  end

  test "mapper reuses the existing deterministic device when interface MAC is seen on a new IP",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    old_ip = unique_test_ip(100, 120, uniq)
    new_ip = unique_test_ip(100, 121, uniq + 1)
    mac = unique_global_test_mac(uniq)
    normalized_mac = IdentityReconciler.normalize_mac(mac)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    old_payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{old_ip}",
          "partition" => "default",
          "device_ip" => old_ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac,
          "timestamp" => ts
        }
      ])

    new_payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{new_ip}",
          "partition" => "default",
          "device_ip" => new_ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(old_payload, %{})

    {:ok, [device_after_old]} =
      Device
      |> Ash.Query.for_read(:by_ip, %{ip: old_ip})
      |> Ash.read(actor: actor)

    assert device_after_old.metadata["identity_source"] == "mapper_primary_mac_seed"
    assert device_after_old.mac == normalized_mac

    assert :ok = MapperResultsIngestor.ingest_interfaces(new_payload, %{})

    # The MAC identifies the device, so the poll at the new address resolves to it, and the
    # device moves there: the old address is not one it reports any more.
    assert [moved] = wait_for_devices_by_ip(actor, new_ip)
    assert moved.uid == device_after_old.uid
    assert wait_for_devices_by_ip(actor, old_ip, 1) == []

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_id == ^device_after_old.uid)
      |> Ash.read(actor: actor)

    assert Enum.any?(interfaces, fn interface ->
             IdentityReconciler.normalize_mac(interface.if_phys_address) == normalized_mac
           end)

    {:ok, old_aliases} = DeviceAliasState.lookup_by_value(:ip, old_ip, actor: actor)
    assert Enum.any?(old_aliases, &(&1.device_id == device_after_old.uid))

    {:ok, new_aliases} = DeviceAliasState.lookup_by_value(:ip, new_ip, actor: actor)
    assert Enum.any?(new_aliases, &(&1.device_id == device_after_old.uid))
  end

  test "mapper device creation registers interface MAC evidence through DIRE without the polling agent identity",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 51, 100, uniq)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    mac = unique_global_test_mac(uniq)
    normalized_mac = IdentityReconciler.normalize_mac(mac)
    polling_agent_id = "agent-mapper-poller-#{uniq}"

    payload =
      Jason.encode!([
        %{
          "agent_id" => polling_agent_id,
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    devices = wait_for_devices_by_ip(actor, ip)
    assert length(devices) == 1
    device = hd(devices)

    # The interface MAC is registered as identity evidence for the polled
    # device, with confidence derived from the IEEE local bit.
    query =
      Ash.Query.for_read(DeviceIdentifier, :lookup, %{
        identifier_type: :mac,
        identifier_value: normalized_mac,
        partition: "default"
      })

    assert {:ok, [identifier | _]} = Ash.read(query, actor: actor)
    assert identifier.device_id == device.uid
    assert identifier.confidence == :strong

    # Polling Agent Exclusion: the agent that performed the poll must never
    # be registered as an identifier of the polled device.
    {:ok, device_identifiers} =
      DeviceIdentifier
      |> Ash.Query.for_read(:by_device, %{device_id: device.uid})
      |> Ash.read(actor: actor)

    refute Enum.any?(device_identifiers, &(&1.identifier_type == :agent_id))

    refute Enum.any?(
             device_identifiers,
             &(to_string(&1.identifier_value) == polling_agent_id)
           )
  end

  test "mapper resolves to existing device when interface MAC matches a registered identifier",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    existing_uid = "sr:" <> Ecto.UUID.generate()
    existing_ip = unique_test_ip(10, 30, uniq)
    new_ip = unique_test_ip(10, 31, uniq + 1)
    mac = unique_global_test_mac(uniq)
    normalized_mac = IdentityReconciler.normalize_mac(mac)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    # Existing device with a non-deterministic uid: only the identifier row
    # (not uid derivation) can resolve the mapper update onto it.
    {:ok, _existing} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: existing_uid, ip: existing_ip})
      |> Ash.create(actor: actor)

    assert :ok =
             IdentityReconciler.register_identifiers(
               existing_uid,
               %{
                 agent_id: nil,
                 armis_id: nil,
                 integration_id: nil,
                 netbox_id: nil,
                 mac: normalized_mac,
                 macs: [normalized_mac],
                 legacy_mac: nil,
                 ip: existing_ip,
                 partition: "default"
               },
               actor: actor
             )

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{new_ip}",
          "partition" => "default",
          "device_ip" => new_ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    # No new device: DIRE resolves the MAC identifier to the existing device, which moves to
    # the polled address.
    assert [moved] = wait_for_devices_by_ip(actor, new_ip)
    assert moved.uid == existing_uid

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_id == ^existing_uid)
      |> Ash.read(actor: actor)

    assert Enum.any?(interfaces, fn interface ->
             IdentityReconciler.normalize_mac(interface.if_phys_address) == normalized_mac
           end)
  end

  test "a MAC-identified poll never lands on a stale alias holder of the polled address", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    holder_uid = "sr:" <> Ecto.UUID.generate()
    holder_ip = unique_test_ip(10, 10, uniq)
    stale_alias_ip = unique_test_ip(198, 18, uniq + 1)
    mac = unique_global_test_mac(uniq)
    normalized_mac = IdentityReconciler.normalize_mac(mac)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok, _holder} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: holder_uid, ip: holder_ip})
      |> Ash.create(actor: actor)

    {:ok, alias_state} =
      DeviceAliasState.create_detected(
        %{
          device_id: holder_uid,
          partition: "default",
          alias_type: :ip,
          alias_value: stale_alias_ip,
          metadata: %{"source" => "test"}
        },
        actor: actor
      )

    {:ok, _stale} = DeviceAliasState.mark_stale(alias_state, actor: actor)

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{stale_alias_ip}",
          "partition" => "default",
          "device_ip" => stale_alias_ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => mac,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    # The polled device reports a MAC no record holds, so it is a device of its own, whatever
    # a stale alias says about the address it was polled at.
    polled_uid = mac_owner(actor, normalized_mac)
    assert is_binary(polled_uid)
    assert polled_uid != holder_uid
    assert [%Device{uid: ^polled_uid}] = wait_for_devices_by_ip(actor, stale_alias_ip)

    assert interface_macs_of(actor, holder_uid) == MapSet.new()
    assert MapSet.member?(interface_macs_of(actor, polled_uid), normalized_mac)

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_ip == ^stale_alias_ip)
      |> Ash.read(actor: actor)

    assert interfaces != []
    assert Enum.all?(interfaces, &(&1.device_id == polled_uid))

    {:ok, aliases} = DeviceAliasState.lookup_by_value(:ip, stale_alias_ip, actor: actor)

    refute Enum.any?(aliases, &(&1.device_id == holder_uid and &1.state == :confirmed))
  end

  test "a device polled at an address another device's record still holds gets its own record",
       %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 51, 10, uniq)
    mac_a = unique_global_test_mac(uniq)
    mac_b = unique_global_test_mac(uniq + 1)
    normalized_a = IdentityReconciler.normalize_mac(mac_a)
    normalized_b = IdentityReconciler.normalize_mac(mac_b)

    # Device A is polled at the address and gets a record there.
    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(ip, [mac_a]), %{})
    assert [%Device{uid: a_uid}] = wait_for_devices_by_ip(actor, ip)
    assert mac_owner(actor, normalized_a) == a_uid

    # DHCP moves A away and gives the address to device B; A's record still holds it. Polling B
    # there must not hand B's interface table to A's record.
    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(ip, [mac_b]), %{})

    b_uid = mac_owner(actor, normalized_b)
    assert is_binary(b_uid)
    assert b_uid != a_uid

    refute MapSet.member?(interface_macs_of(actor, a_uid), normalized_b)
    assert MapSet.member?(interface_macs_of(actor, b_uid), normalized_b)

    {:ok, b_interfaces} =
      Interface
      |> Ash.Query.filter(device_id == ^b_uid)
      |> Ash.read(actor: actor)

    assert Enum.any?(b_interfaces, fn interface ->
             IdentityReconciler.normalize_mac(interface.if_phys_address) == normalized_b
           end)
  end

  test "a randomized MAC never identifies the polled device", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    owner_uid = "sr:" <> Ecto.UUID.generate()
    owner_ip = unique_test_ip(198, 51, 30, uniq)
    polled_ip = unique_test_ip(198, 51, 40, uniq + 1)
    laa_mac = unique_laa_test_mac(uniq)
    normalized_laa = IdentityReconciler.normalize_mac(laa_mac)

    {:ok, _owner} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: owner_uid, ip: owner_ip})
      |> Ash.create(actor: actor)

    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: owner_ip,
        mac: laa_mac,
        partition: "default",
        metadata: %{}
      })

    assert :ok = IdentityReconciler.register_identifiers(owner_uid, ids, actor: actor)
    assert mac_owner(actor, normalized_laa) == owner_uid

    assert :ok =
             MapperResultsIngestor.ingest_interfaces(interface_payload(polled_ip, [laa_mac]), %{})

    assert [%Device{uid: polled_uid}] = wait_for_devices_by_ip(actor, polled_ip)
    assert polled_uid != owner_uid
    assert mac_owner(actor, normalized_laa) == owner_uid
    assert interface_macs_of(actor, owner_uid) == MapSet.new()
  end

  test "a poll does not revive a device an operator deleted", %{actor: actor} do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 51, 50, uniq)
    new_ip = unique_test_ip(198, 51, 60, uniq + 1)
    mac = unique_global_test_mac(uniq)

    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(ip, [mac]), %{})
    assert [%Device{uid: uid} = device] = wait_for_devices_by_ip(actor, ip)

    assert {:ok, _deleted} =
             Device.soft_delete(device, "manual", Ecto.UUID.generate(), actor: actor)

    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(new_ip, [mac]), %{})

    assert {:ok, tombstone} = Device.get_by_uid(uid, true, actor: actor)
    assert tombstone.deleted_at
    assert tombstone.deleted_reason == "manual"
    assert wait_for_devices_by_ip(actor, new_ip, 1) == []

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_ip == ^new_ip)
      |> Ash.read(actor: actor)

    assert interfaces == []
    assert revival_audit_rows(uid) == []
  end

  test "a poll restores a device an automatic process deleted, through the audited restore", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 51, 70, uniq)
    mac = unique_global_test_mac(uniq)

    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(ip, [mac]), %{})
    assert [%Device{uid: uid} = device] = wait_for_devices_by_ip(actor, ip)

    assert {:ok, deleted} =
             Device.soft_delete(device, "stale", "system:mapper_test_reaper", actor: actor)

    assert :ok = MapperResultsIngestor.ingest_interfaces(interface_payload(ip, [mac]), %{})

    assert {:ok, restored} = Device.get_by_uid(uid, false, actor: actor)
    assert restored.deleted_at == nil
    assert restored.deleted_by == nil
    assert restored.identity_revision > deleted.identity_revision

    assert [{"system:mapper_test_reaper", "stale"}] = revival_audit_rows(uid)

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_id == ^uid)
      |> Ash.read(actor: actor)

    assert interfaces != []
  end

  test "a device polled at two of its own addresses stays one device at its first address", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    wan_ip = unique_test_ip(203, 0, 113, uniq)
    lan_ip = unique_test_ip(198, 51, 20, uniq + 1)
    wan_mac = unique_global_test_mac(uniq)
    lan_mac = unique_global_test_mac(uniq + 1)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    interfaces = fn device_ip ->
      Jason.encode!([
        %{
          "device_id" => "default:#{device_ip}",
          "partition" => "default",
          "device_ip" => device_ip,
          "if_index" => 1,
          "if_name" => "wan0",
          "if_phys_address" => wan_mac,
          "ip_addresses" => [wan_ip <> "/24"],
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{device_ip}",
          "partition" => "default",
          "device_ip" => device_ip,
          "if_index" => 2,
          "if_name" => "lan0",
          "if_phys_address" => lan_mac,
          "ip_addresses" => [lan_ip <> "/24"],
          "timestamp" => ts
        }
      ])
    end

    assert :ok = MapperResultsIngestor.ingest_interfaces(interfaces.(wan_ip), %{})
    assert [%Device{uid: router_uid}] = wait_for_devices_by_ip(actor, wan_ip)

    assert :ok = MapperResultsIngestor.ingest_interfaces(interfaces.(lan_ip), %{})

    # Both polls resolve to the one record the interface MACs identify, and the record keeps
    # its address: the WAN address is still one the router reports.
    assert [%Device{uid: ^router_uid}] = wait_for_devices_by_ip(actor, wan_ip)
    assert wait_for_devices_by_ip(actor, lan_ip, 1) == []

    {:ok, lan_polled} =
      Interface
      |> Ash.Query.filter(device_ip == ^lan_ip)
      |> Ash.read(actor: actor)

    assert lan_polled != []
    assert Enum.all?(lan_polled, &(&1.device_id == router_uid))
  end

  test "mapper alias updates do not promote mismatched device_ip records onto the management alias",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    mgmt_ip = unique_test_ip(192, 0, 2, uniq)
    stray_ip = unique_test_ip(192, 0, 2, uniq + 1)
    mac_a = unique_global_test_mac(uniq)
    mac_b = unique_global_test_mac(uniq + 1)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 1,
          "if_name" => "wlan0",
          "if_phys_address" => mac_a,
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => stray_ip,
          "if_index" => 2,
          "if_name" => "wlan1",
          "if_phys_address" => mac_b,
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    assert {:ok, mgmt_aliases} = DeviceAliasState.lookup_by_value(:ip, mgmt_ip, actor: actor)
    assert Enum.any?(mgmt_aliases, &(&1.state in [:detected, :updated, :confirmed]))

    assert {:ok, stray_aliases} = DeviceAliasState.lookup_by_value(:ip, stray_ip, actor: actor)
    assert Enum.all?(stray_aliases, &(&1.device_id != hd(mgmt_aliases).device_id))

    {:ok, stray_devices} =
      Device
      |> Ash.Query.for_read(:by_ip, %{ip: stray_ip})
      |> Ash.read(actor: actor)

    assert length(stray_devices) == 1
    assert hd(stray_devices).metadata["identity_source"] == "mapper_primary_mac_seed"
  end

  test "mapper alias updates do not promote router interface IPs into device aliases on stable device_ip",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    mgmt_ip = unique_test_ip(198, 18, 10, uniq)
    lan_alias = unique_test_ip(10, 0, 0, uniq + 1)
    vlan_alias = unique_test_ip(10, 0, 1, uniq + 2)
    shared_bridge_mac = unique_global_test_mac(uniq)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 1,
          "if_name" => "br0",
          "if_phys_address" => shared_bridge_mac,
          "ip_addresses" => [lan_alias],
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 2,
          "if_name" => "br100",
          "if_phys_address" => shared_bridge_mac,
          "ip_addresses" => [vlan_alias],
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    assert {:ok, mgmt_aliases} = DeviceAliasState.lookup_by_value(:ip, mgmt_ip, actor: actor)
    assert Enum.any?(mgmt_aliases, &(&1.state in [:detected, :updated, :confirmed]))

    assert {:ok, []} = DeviceAliasState.lookup_by_value(:ip, lan_alias, actor: actor)
    assert {:ok, []} = DeviceAliasState.lookup_by_value(:ip, vlan_alias, actor: actor)
  end

  test "an address-only poll prefers the canonical UID when duplicate devices share IP", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 19, uniq)
    canonical_uid = "sr:" <> Ecto.UUID.generate()
    provisional_uid = "sr:" <> Ecto.UUID.generate()
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok, _canonical} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: canonical_uid,
        ip: ip,
        metadata: %{"identity_state" => "canonical", "identity_source" => "unifi-api"}
      })
      |> Ash.create(actor: actor)

    provisional_temp_ip = unique_test_ip(198, 20, uniq + 1)

    {:ok, provisional} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: provisional_uid,
        ip: provisional_temp_ip,
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_topology_sighting"
        }
      })
      |> Ash.create(actor: actor)

    {:ok, _deleted} =
      provisional
      |> Ash.Changeset.for_update(
        :soft_delete,
        %{
          deleted_reason: "mapper_test_duplicate",
          deleted_by: "system:mapper_device_creation_test"
        },
        actor: actor
      )
      |> Ash.update(actor: actor)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET ip = $1 WHERE uid = $2",
      [ip, provisional_uid]
    )

    # No interface MAC: the polled address is the only evidence there is.
    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    {:ok, interfaces} =
      Interface
      |> Ash.Query.filter(device_ip == ^ip)
      |> Ash.read(actor: actor)

    assert Enum.any?(interfaces, &(&1.device_id == canonical_uid))
    refute Enum.any?(interfaces, &(&1.device_id == provisional_uid))
  end

  defp wait_for_devices_by_ip(actor, ip, attempts \\ 60)

  defp wait_for_devices_by_ip(actor, ip, attempts) when attempts > 0 do
    case Device |> Ash.Query.for_read(:by_ip, %{ip: ip}) |> Ash.read(actor: actor) do
      {:ok, %Ash.Page.Keyset{results: [%Device{} | _] = devices}} ->
        devices

      {:ok, [%Device{} | _] = devices} ->
        devices

      _ ->
        Process.sleep(100)
        wait_for_devices_by_ip(actor, ip, attempts - 1)
    end
  end

  defp wait_for_devices_by_ip(_actor, _ip, 0), do: []

  defp interface_payload(device_ip, macs) do
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    macs
    |> Enum.with_index(1)
    |> Enum.map(fn {mac, index} ->
      %{
        "device_id" => "default:#{device_ip}",
        "partition" => "default",
        "device_ip" => device_ip,
        "if_index" => index,
        "if_name" => "eth#{index}",
        "if_phys_address" => mac,
        "timestamp" => ts
      }
    end)
    |> Jason.encode!()
  end

  defp mac_owner(actor, normalized_mac) do
    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: :mac,
      identifier_value: normalized_mac,
      partition: "default"
    })
    |> Ash.read!(actor: actor)
    |> case do
      [identifier] -> identifier.device_id
      [] -> nil
    end
  end

  defp interface_macs_of(actor, device_uid),
    do: InterfaceMacs.registered_values(device_uid, actor)

  defp revival_audit_rows(device_uid) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT previous_deleted_by, previous_deleted_reason
        FROM platform.device_revival_audit
        WHERE device_uid = $1
        ORDER BY event_id
        """,
        [device_uid]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp unique_test_ip(a, b, seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "#{a}.#{b}.#{third}.#{fourth}"
  end

  defp unique_test_ip(a, b, c, seed) do
    third = rem(c + div(seed, 250), 250) + 1
    fourth = rem(seed, 250) + 1
    "#{a}.#{b}.#{third}.#{fourth}"
  end

  # Globally-unique unicast MAC (multicast + locally-administered bits of the
  # first octet cleared) so DIRE registers it with :strong confidence.
  defp unique_global_test_mac(seed) do
    <<b1, b2, b3, b4, b5, b6, _::binary>> =
      :crypto.hash(:sha256, "#{seed}:#{Ecto.UUID.generate()}")

    Enum.map_join(
      [Bitwise.band(b1, 0xFC), b2, b3, b4, b5, b6],
      ":",
      &Base.encode16(<<&1>>, case: :upper)
    )
  end

  defp wait_for_aliases(actor, type, value, predicate, attempts \\ 60)

  defp wait_for_aliases(actor, type, value, predicate, attempts) when attempts > 0 do
    case DeviceAliasState.lookup_by_value(type, value, actor: actor) do
      {:ok, aliases} ->
        if predicate.(aliases) do
          aliases
        else
          Process.sleep(100)
          wait_for_aliases(actor, type, value, predicate, attempts - 1)
        end

      _ ->
        Process.sleep(100)
        wait_for_aliases(actor, type, value, predicate, attempts - 1)
    end
  end

  defp wait_for_aliases(_actor, _type, _value, _predicate, 0), do: []

  # Locally administered unicast MAC (the IEEE local bit of the first octet set): a
  # randomized or virtual address that never identifies a device.
  defp unique_laa_test_mac(seed) do
    <<b1, b2, b3, b4, b5, b6, _::binary>> =
      :crypto.hash(:sha256, "#{seed}:#{Ecto.UUID.generate()}")

    Enum.map_join(
      [Bitwise.bor(Bitwise.band(b1, 0xFC), 0x02), b2, b3, b4, b5, b6],
      ":",
      &Base.encode16(<<&1>>, case: :upper)
    )
  end
end
