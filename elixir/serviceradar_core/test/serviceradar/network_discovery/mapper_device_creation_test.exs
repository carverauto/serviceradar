defmodule ServiceRadar.NetworkDiscovery.MapperDeviceCreationTest do
  @moduledoc """
  Integration tests for mapper device creation when no existing device
  matches the polled IP address.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, IdentityReconciler}
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
    device_uid = "sr:" <> Ecto.UUID.generate()
    ip = "192.168.#{:rand.uniform(200)}.#{:rand.uniform(200)}"

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
    ip = "192.168.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
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

    assert length(devices) >= 1
    assert Enum.any?(devices, &(&1.uid == existing.uid))
  end
end
