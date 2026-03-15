defmodule ServiceRadar.Inventory.IdentityReconcilerUnmergeTest do
  @moduledoc """
  Tests for device unmerge behavior.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Inventory.MergeAudit
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_unmerge_test)
    {:ok, actor: actor}
  end

  test "unmerge restores from-device and records audit entry", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "canonical-device", "10.0.10.1")
    {:ok, device_b} = create_device(actor, "merged-device", "10.0.10.2")

    mac = "00AA#{mac_suffix()}#{mac_suffix()}"

    # Register MAC on device_b
    assert {:ok, _} = register_identifier(actor, device_b.uid, :mac, mac)

    # Merge device_b into device_a (with identifier details for later reassignment)
    assert :ok =
             IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
               actor: actor,
               reason: "identifier_conflict",
               details: %{
                 identifiers: [%{type: :mac, value: mac}],
                 from_device_ip: "10.0.10.2",
                 from_device_hostname: "merged-device"
               }
             )

    # Verify device_b is gone
    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)

    # Unmerge
    assert :ok = IdentityReconciler.unmerge_device(device_b.uid, actor: actor)

    # Verify device_b is restored
    assert {:ok, restored} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert restored.uid == device_b.uid

    # Verify both the original merge audit and the compensating unmerge audit exist
    {:ok, audits} = MergeAudit.get_by_device(device_b.uid, actor: actor)
    assert Enum.any?(audits, &(&1.reason == "identifier_conflict"))
    assert Enum.any?(audits, &(&1.reason == "unmerge"))
  end

  test "unmerge returns error when no merge audit exists", %{actor: actor} do
    fake_device_id = "sr:" <> Ecto.UUID.generate()

    assert {:error, :no_merge_audit_found} =
             IdentityReconciler.unmerge_device(fake_device_id, actor: actor)
  end

  defp create_device(actor, hostname, ip) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
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
    [:positive]
    |> System.unique_integer()
    |> rem(256)
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
  end
end
