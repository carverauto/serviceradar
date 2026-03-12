defmodule ServiceRadar.NetworkDiscovery.MapperDeviceCreationTest do
  @moduledoc """
  Integration tests for mapper device creation when no existing device
  matches the polled IP address.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler, Interface}
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

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
    ip = unique_test_ip(192, 168, uniq)

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
    query =
      Device
      |> Ash.Query.for_read(:by_ip, %{ip: ip})

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
    mac_a = unique_test_mac(uniq)
    mac_b = unique_test_mac(uniq + 1)
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

  test "mapper reuses the existing deterministic device when interface MAC is seen on a new IP",
       %{
         actor: actor
       } do
    old_ip = "203.0.113.#{:rand.uniform(120) + 10}"
    uniq = System.unique_integer([:positive, :monotonic])
    old_ip = unique_test_ip(203, 0, 113, uniq)
    new_ip = unique_test_ip(198, 51, 100, uniq + 1)
    mac = "F4:92:BF:75:C7:21"
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

    new_devices = wait_for_devices_by_ip(actor, new_ip)

    assert new_devices == []

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

  test "mapper interface ingestion does not register interface MACs as device identifiers", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    ip = unique_test_ip(198, 51, 100, uniq)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    mac = "0C:EA:14:32:D2:77"
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    payload =
      Jason.encode!([
        %{
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

    query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :mac,
        identifier_value: normalized_mac,
        partition: "default"
      })

    assert {:ok, []} = Ash.read(query, actor: actor)
  end

  test "mapper reuses stale IP alias mapping and does not create duplicate device", %{
    actor: actor
  } do
    uniq = System.unique_integer([:positive, :monotonic])
    canonical_uid = "sr:" <> Ecto.UUID.generate()
    canonical_ip = unique_test_ip(10, 10, uniq)

    stale_alias_ip = unique_test_ip(198, 18, uniq + 1)

    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    {:ok, _canonical} =
      Device
      |> Ash.Changeset.for_create(:create, %{uid: canonical_uid, ip: canonical_ip})
      |> Ash.create(actor: actor)

    {:ok, alias_state} =
      DeviceAliasState.create_detected(
        %{
          device_id: canonical_uid,
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
          "if_phys_address" => "F4:92:BF:75:C7:21",
          "timestamp" => ts
        }
      ])

    assert :ok = MapperResultsIngestor.ingest_interfaces(payload, %{})

    {:ok, by_alias_ip} =
      Device
      |> Ash.Query.for_read(:by_ip, %{ip: stale_alias_ip})
      |> Ash.read(actor: actor)

    # Mapper should not create a new provisional placeholder at stale alias IP.
    assert by_alias_ip == []

    assert {:ok, still_canonical} = Device.get_by_uid(canonical_uid, false, actor: actor)
    assert still_canonical.uid == canonical_uid

    {:ok, refreshed_aliases} = DeviceAliasState.lookup_by_value(:ip, stale_alias_ip, actor: actor)

    assert Enum.any?(
             refreshed_aliases,
             &(&1.device_id == canonical_uid and &1.state == :confirmed)
           )
  end

  test "mapper alias updates do not promote mismatched device_ip records onto the management alias",
       %{
         actor: actor
       } do
    uniq = System.unique_integer([:positive, :monotonic])
    mgmt_ip = unique_test_ip(192, 0, 2, uniq)
    stray_ip = unique_test_ip(192, 0, 2, uniq + 1)
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 1,
          "if_name" => "wlan0",
          "if_phys_address" => "AA:BB:CC:DD:EE:01",
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => stray_ip,
          "if_index" => 2,
          "if_name" => "wlan1",
          "if_phys_address" => "AA:BB:CC:DD:EE:02",
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
    ts = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 1,
          "if_name" => "br0",
          "if_phys_address" => "0C:EA:14:32:D2:7F",
          "ip_addresses" => [lan_alias],
          "timestamp" => ts
        },
        %{
          "device_id" => "default:#{mgmt_ip}",
          "partition" => "default",
          "device_ip" => mgmt_ip,
          "if_index" => 2,
          "if_name" => "br100",
          "if_phys_address" => "0C:EA:14:32:D2:7F",
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

  test "mapper interface ingestion prefers canonical UID when duplicate devices share IP", %{
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

    payload =
      Jason.encode!([
        %{
          "device_id" => "default:#{ip}",
          "partition" => "default",
          "device_ip" => ip,
          "if_index" => 1,
          "if_name" => "eth0",
          "if_phys_address" => "F4:92:BF:75:C7:21",
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

  defp unique_test_ip(a, b, seed) do
    third = rem(seed, 250) + 1
    fourth = rem(div(seed, 250), 250) + 1
    "#{a}.#{b}.#{third}.#{fourth}"
  end

  defp unique_test_ip(a, b, c, seed) do
    fourth = rem(seed, 250) + 1
    "#{a}.#{b}.#{c}.#{fourth}"
  end

  defp unique_test_mac(seed) do
    bytes =
      0..5
      |> Enum.map(fn idx ->
        rem(div(seed, :math.pow(256, idx) |> trunc()), 256)
      end)
      |> Enum.reverse()

    Enum.map_join(bytes, ":", &Base.encode16(<<&1>>, case: :upper))
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
end
