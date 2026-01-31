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

  defp create_device(actor, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: "10.10.0.#{:rand.uniform(200)}"
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
