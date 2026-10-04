defmodule ServiceRadar.Inventory.IdentityReconcilerIpDedupTest do
  @moduledoc """
  Integration coverage for IP-based de-duplication behavior.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_ip_dedup_test)
    {:ok, actor: actor}
  end

  test "IP fallback does not override strong identifiers", %{actor: actor} do
    # Per device-identity-reconciliation spec ("Single Canonical Resolution
    # Path"): an update carrying a strong identifier must never be assigned
    # a device via IP fallback — that adoption collapsed distinct devices.
    ip = unique_ip()
    {:ok, device} = create_device(actor, ip, "existing-device")

    update = %{
      device_id: nil,
      ip: ip,
      mac: "00:00:5E:00:53:FF",
      partition: "default",
      metadata: %{}
    }

    assert {:ok, resolved_id} = IdentityReconciler.resolve_device_id(update, actor: actor)
    refute resolved_id == device.uid
  end

  # #4760: a locally administered (randomized) MAC is not a strong identifier, so an update
  # whose only MAC is one is an address-only sighting and IP fallback applies to it.
  test "IP fallback applies to an update whose only MAC is locally administered", %{
    actor: actor
  } do
    ip = unique_ip()
    {:ok, device} = create_device(actor, ip, "existing-randomized-mac-device")

    update = %{
      device_id: nil,
      ip: ip,
      mac: unique_local_mac(),
      partition: "default",
      metadata: %{}
    }

    assert {:ok, resolved_id} = IdentityReconciler.resolve_device_id(update, actor: actor)
    assert resolved_id == device.uid
  end

  test "a failed address lookup does not mint a device", %{actor: actor} do
    ip = unique_ip()
    {:ok, device} = create_device(actor, ip, "host01.example.com")

    update = %{
      device_id: nil,
      ip: ip,
      mac: nil,
      partition: "default",
      metadata: %{}
    }

    assert {:ok, resolved_id} = IdentityReconciler.resolve_device_id(update, actor: actor)
    assert resolved_id == device.uid

    parent = self()

    spawn(fn ->
      send(parent, {:resolved, IdentityReconciler.resolve_device_id(update, actor: actor)})
    end)

    assert_receive {:resolved, result}, 30_000
    assert {:error, {:identifier_lookup_failed, _reason}} = result
  end

  test "IP fallback reuses existing device for weak updates", %{actor: actor} do
    ip = unique_ip()
    {:ok, device} = create_device(actor, ip, "existing-weak-device")

    update = %{
      device_id: nil,
      ip: ip,
      mac: nil,
      partition: "default",
      metadata: %{}
    }

    assert {:ok, resolved_id} = IdentityReconciler.resolve_device_id(update, actor: actor)
    assert resolved_id == device.uid
  end

  test "active devices cannot share a primary IP", %{actor: actor} do
    ip = unique_ip()

    {:ok, _device_a} = create_device(actor, ip, "duplicate-a")
    assert {:error, _reason} = create_device(actor, ip, "duplicate-b")
  end

  defp create_device(actor, ip, hostname) do
    attrs = %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: hostname,
      ip: ip
    }

    Device
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  # A locally administered MAC (0x02 set in the first octet) no other test registers.
  defp unique_local_mac do
    n = System.unique_integer([:positive, :monotonic])
    "06" <> (n |> Integer.to_string(16) |> String.pad_leading(10, "0"))
  end

  # Benchmarking range (198.18.0.0/15), one address per call, never reused in this run.
  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    "198.#{18 + rem(div(n, 254 * 256), 2)}.#{rem(div(n, 254), 256)}.#{rem(n, 254) + 1}"
  end
end
