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

    assert {:error, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_b.uid, false, actor: actor)

    mac_query =
      DeviceIdentifier
      |> Ash.Query.for_read(:lookup, %{
        identifier_type: :mac,
        identifier_value: normalized_mac,
        partition: "default"
      })

    assert {:ok, [identifier | _]} = Ash.read(mac_query, actor: actor)
    assert identifier.device_id == device_b.uid

    assert {:ok, [audit | _]} = MergeAudit.get_merged_to(device_a.uid, actor: actor)
    assert audit.to_device_id == device_b.uid
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

    ids =
      IdentityReconciler.extract_strong_identifiers(%{
        device_id: nil,
        ip: "10.30.0.1",
        mac: nil,
        partition: "default",
        metadata: %{"agent_id" => agent_id}
      })

    assert IdentityReconciler.has_strong_identifier?(ids)
    assert {:agent_id, ^agent_id} = IdentityReconciler.highest_priority_identifier(ids)
  end

  test "single non-MAC strong sighting does not promote provisional identity state", %{
    actor: actor
  } do
    provisional_uid = "sr:" <> Ecto.UUID.generate()
    ip = "10.77.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
    armis_id = "armis-promote-#{System.unique_integer([:positive])}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: provisional_uid,
        ip: ip,
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      })
      |> Ash.create(actor: actor)

    ids = %{
      agent_id: nil,
      armis_id: armis_id,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: ip,
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(provisional_uid, ids, actor: actor)
    assert {:ok, still_provisional} = Device.get_by_uid(provisional_uid, false, actor: actor)
    assert still_provisional.metadata["identity_state"] == "provisional"

    assert still_provisional.metadata["identity_promotion_blocked_reason"] ==
             "insufficient_corroboration"

    refute Map.has_key?(still_provisional.metadata, "identity_promoted_at")
  end

  test "repeated non-MAC strong sightings promote provisional identity state", %{actor: actor} do
    provisional_uid = "sr:" <> Ecto.UUID.generate()
    ip = "10.78.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
    armis_id = "armis-repeat-#{System.unique_integer([:positive])}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: provisional_uid,
        ip: ip,
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      })
      |> Ash.create(actor: actor)

    ids = %{
      agent_id: nil,
      armis_id: armis_id,
      integration_id: nil,
      netbox_id: nil,
      mac: nil,
      ip: ip,
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(provisional_uid, ids, actor: actor)
    assert {:ok, first_pass} = Device.get_by_uid(provisional_uid, false, actor: actor)
    assert first_pass.metadata["identity_state"] == "provisional"

    assert :ok = IdentityReconciler.register_identifiers(provisional_uid, ids, actor: actor)
    assert {:ok, promoted} = Device.get_by_uid(provisional_uid, false, actor: actor)
    assert promoted.metadata["identity_state"] == "canonical"
    assert promoted.metadata["identity_promoted_by"] == "dire"
    assert is_binary(promoted.metadata["identity_promoted_at"])
    assert promoted.metadata["identity_promotion_policy"] == "corroborated_strong_identifier"
    assert promoted.metadata["identity_promotion_non_mac_sighting_count"] == 2
  end

  test "multiple non-MAC strong identifiers in one update promote provisional identity state", %{
    actor: actor
  } do
    provisional_uid = "sr:" <> Ecto.UUID.generate()
    ip = "10.79.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
    armis_id = "armis-corroborated-#{System.unique_integer([:positive])}"
    netbox_id = "netbox-corroborated-#{System.unique_integer([:positive])}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: provisional_uid,
        ip: ip,
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      })
      |> Ash.create(actor: actor)

    ids = %{
      agent_id: nil,
      armis_id: armis_id,
      integration_id: nil,
      netbox_id: netbox_id,
      mac: nil,
      ip: ip,
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(provisional_uid, ids, actor: actor)
    assert {:ok, promoted} = Device.get_by_uid(provisional_uid, false, actor: actor)
    assert promoted.metadata["identity_state"] == "canonical"
    assert promoted.metadata["identity_promotion_policy"] == "corroborated_strong_identifier"

    assert Enum.sort(promoted.metadata["identity_promotion_types_seen"]) == [
             "armis_device_id",
             "netbox_device_id"
           ]
  end

  test "MAC-only identifier does not promote provisional identity state", %{actor: actor} do
    provisional_uid = "sr:" <> Ecto.UUID.generate()
    ip = "10.88.#{:rand.uniform(200)}.#{:rand.uniform(200)}"
    mac = "AA:BB:CC:DD:EE:#{mac_suffix()}"
    normalized_mac = IdentityReconciler.normalize_mac(mac)

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: provisional_uid,
        ip: ip,
        metadata: %{
          "identity_state" => "provisional",
          "identity_source" => "mapper_ip_seed"
        }
      })
      |> Ash.create(actor: actor)

    ids = %{
      agent_id: nil,
      armis_id: nil,
      integration_id: nil,
      netbox_id: nil,
      mac: normalized_mac,
      ip: ip,
      partition: "default"
    }

    assert :ok = IdentityReconciler.register_identifiers(provisional_uid, ids, actor: actor)
    assert {:ok, still_provisional} = Device.get_by_uid(provisional_uid, false, actor: actor)
    assert still_provisional.metadata["identity_state"] == "provisional"
    refute Map.has_key?(still_provisional.metadata, "identity_promoted_at")
  end

  defp create_device(actor, hostname) do
    create_device_with_uid(
      actor,
      "sr:" <> Ecto.UUID.generate(),
      hostname,
      "10.10.0.#{:rand.uniform(200)}"
    )
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
