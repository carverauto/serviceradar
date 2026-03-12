defmodule ServiceRadar.Inventory.IdentityReconcilerIpDedupTest do
  @moduledoc """
  Integration coverage for IP-based de-duplication behavior.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.{Device, IdentityReconciler}
  alias ServiceRadar.TestSupport

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    actor = SystemActor.system(:identity_reconciler_ip_dedup_test)
    {:ok, actor: actor}
  end

  test "IP fallback reuses existing device even with strong identifiers", %{actor: actor} do
    ip = unique_ip()
    {:ok, device} = create_device(actor, ip, "existing-device")

    update = %{
      device_id: nil,
      ip: ip,
      mac: "AA:BB:CC:DD:EE:FF",
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

  defp unique_ip do
    suffix = rem(System.unique_integer([:positive]), 200) + 1
    "10.250.0.#{suffix}"
  end
end
