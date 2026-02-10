defmodule ServiceRadar.Inventory.IdentityReconcilerIdentifiersTest do
  @moduledoc """
  Integration coverage for multi-identifier resolution and merge outcomes.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, DeviceIdentifier, IdentityReconciler, MergeAudit}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_identifiers_test)
    {:ok, actor: actor}
  end

  test "register_identifiers merges conflicting strong identifiers", %{actor: actor} do
    armis_id = "armis-#{System.unique_integer([:positive])}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    {:ok, device_a} = create_device(actor, "device-a")
    {:ok, device_b} = create_device(actor, "device-b")

    assert {:ok, _} = register_identifier(actor, device_a.uid, :armis_device_id, armis_id)
    assert {:ok, _} = register_identifier(actor, device_b.uid, :mac, normalized_mac)

    ids = %{
      agent_id: nil,
      armis_id: armis_id,
      integration_id: nil,
      netbox_id: nil,
      mac: normalized_mac,
      ip: "",
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(device_b.uid, ids, actor: actor)

    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)

    mac_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :mac,
        identifier_value: normalized_mac,
        partition: "default"
      })

    assert {:ok, [identifier | _]} = Ash.read(mac_query, actor: actor)
    assert identifier.device_id == device_a.uid

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(device_b.uid, actor: actor)
    assert audit.to_device_id == device_a.uid
  end

  test "agent_id resolves to same device after IP change", %{actor: actor} do
    agent_id = "k8s-agent-#{System.unique_integer([:positive])}"
    original_ip = "10.20.0.#{:rand.uniform(200)}"
    new_ip = "10.20.1.#{:rand.uniform(200)}"

    # First resolution with original IP — generates deterministic device ID from agent_id
    update_1 = %{
      device_id: nil,
      ip: original_ip,
      mac: nil,
      partition: "default",
      metadata: %{"agent_id" => agent_id, "hostname" => "test-pod"}
    }

    {:ok, device_uid_1} = IdentityReconciler.resolve_device_id(update_1, actor: actor)
    assert IdentityReconciler.serviceradar_uuid?(device_uid_1)

    # Create the device record (as ensure_device_for_agent would in real flow)
    {:ok, _device} = create_device_with_uid(actor, device_uid_1, "test-pod", original_ip)

    # Register identifiers so the agent_id is persisted in device_identifiers
    ids_1 = IdentityReconciler.extract_strong_identifiers(update_1)
    assert :ok = IdentityReconciler.register_identifiers(device_uid_1, ids_1, actor: actor)

    # Verify agent_id identifier was registered
    agent_id_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :agent_id,
        identifier_value: agent_id,
        partition: "default"
      })

    assert {:ok, [identifier]} = Ash.read(agent_id_query, actor: actor)
    assert identifier.device_id == device_uid_1

    # Second resolution with NEW IP (simulating pod restart)
    update_2 = %{
      device_id: nil,
      ip: new_ip,
      mac: nil,
      partition: "default",
      metadata: %{"agent_id" => agent_id, "hostname" => "test-pod"}
    }

    {:ok, device_uid_2} = IdentityReconciler.resolve_device_id(update_2, actor: actor)

    # Same device_uid despite different IP — agent_id lookup found the existing device
    assert device_uid_2 == device_uid_1
  end

  test "agent_id takes priority over IP for device resolution", %{actor: _actor} do
    agent_id = "priority-agent-#{System.unique_integer([:positive])}"

    ids = IdentityReconciler.extract_strong_identifiers(%{
      device_id: nil,
      ip: "10.30.0.1",
      mac: nil,
      partition: "default",
      metadata: %{"agent_id" => agent_id}
    })

    assert IdentityReconciler.has_strong_identifier?(ids)
    assert {:agent_id, ^agent_id} = IdentityReconciler.highest_priority_identifier(ids)
  end

  defp create_device(actor, hostname) do
    create_device_with_uid(actor, "sr:" <> Ecto.UUID.generate(), hostname, "10.10.0.#{:rand.uniform(200)}")
  end

  defp create_device_with_uid(actor, uid, hostname, ip) do
    attrs = %{
      uid: uid,
      hostname: hostname,
      ip: ip
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp register_identifier(actor, device_id, type, value) do
    attrs = %{
      device_id: device_id,
      identifier_type: type,
      identifier_value: value,
      partition: "default",
      source: "test"
    }

    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, attrs)
    |> Ash.create(actor: actor)
  end

  defp mac_suffix do
    System.unique_integer([:positive])
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
