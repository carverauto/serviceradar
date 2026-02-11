defmodule ServiceRadar.Inventory.IdentityReconcilerHostnameGuardTest do
  @moduledoc """
  Tests for hostname conflict merge guard.
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
    actor = SystemActor.system(:identity_reconciler_hostname_guard_test)
    {:ok, actor: actor}
  end

  test "merge blocked when both devices have different non-empty hostnames", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "tonka01", "10.0.1.1")
    {:ok, device_b} = create_device(actor, "farm01", "10.0.1.2")

    result =
      IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
        actor: actor,
        reason: "identifier_conflict",
        details: %{identifiers: [%{type: :mac, value: "AABBCCDDEEFF"}]}
      )

    assert {:error, {:hostname_conflict, "farm01", "tonka01"}} = result

    # Both devices should still exist
    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
  end

  test "merge proceeds when from-device has no hostname", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "target-host", "10.0.2.1")
    {:ok, device_b} = create_device(actor, nil, "10.0.2.2")

    result =
      IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
        actor: actor,
        reason: "identifier_conflict",
        details: %{}
      )

    assert :ok = result

    # from-device should be gone, to-device should remain
    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
  end

  test "merge proceeds when to-device has no hostname", %{actor: actor} do
    {:ok, device_a} = create_device(actor, nil, "10.0.3.1")
    {:ok, device_b} = create_device(actor, "source-host", "10.0.3.2")

    result =
      IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
        actor: actor,
        reason: "identifier_conflict",
        details: %{}
      )

    assert :ok = result

    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
  end

  test "merge proceeds when both devices have the same hostname", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "same-host", "10.0.4.1")
    {:ok, device_b} = create_device(actor, "same-host", "10.0.4.2")

    result =
      IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
        actor: actor,
        reason: "identifier_conflict",
        details: %{}
      )

    assert :ok = result

    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
  end

  test "merge proceeds when both devices have empty hostnames", %{actor: actor} do
    {:ok, device_a} = create_device(actor, "", "10.0.5.1")
    {:ok, device_b} = create_device(actor, "", "10.0.5.2")

    result =
      IdentityReconciler.merge_devices(device_b.uid, device_a.uid,
        actor: actor,
        reason: "identifier_conflict",
        details: %{}
      )

    assert :ok = result

    assert {:error, _} = Device.get_by_uid(device_b.uid, false, actor: actor)
    assert {:ok, _} = Device.get_by_uid(device_a.uid, false, actor: actor)
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
end
