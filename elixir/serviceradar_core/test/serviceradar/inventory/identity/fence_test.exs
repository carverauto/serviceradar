defmodule ServiceRadar.Inventory.Identity.FenceTest do
  @moduledoc """
  The write half of the identity fence.

  Pinning is only worth having if a superseded pin actually refuses the write, so
  the load-bearing test is the negative one: a merge between resolution and write
  must stop the write landing against an identity that has moved.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.EventWriter.DeviceCorrelation
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.Identity.Fence
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:fence_test)}
  end

  test "a pinned write lands while the revision is unchanged", %{actor: actor} do
    {:ok, device} = create_device(actor)
    pinned = device.identity_revision

    assert {:ok, _} = pinned_touch(device, pinned, actor)
  end

  test "a pinned write is refused after the revision moves", %{actor: actor} do
    {:ok, device} = create_device(actor)
    pinned = device.identity_revision

    # Anything that changes identity composition. A merge is the real case; a
    # direct bump is the same transition without the ceremony.
    {:ok, _} = Device.bump_identity_revision(device, actor: actor)

    assert {:error, error} = pinned_touch(device, pinned, actor)

    assert Fence.stale?(error),
           "a superseded pin must surface as a stale record, not as a silent success"
  end

  test "a merge between resolution and write supersedes the pin", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)

    # Pin the survivor as an in-flight consumer would.
    pinned = revision(actor, survivor.uid)
    {:ok, fresh} = Device.get_by_uid(survivor.uid, false, actor: actor)

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    assert {:error, error} = pinned_touch(fresh, pinned, actor)

    assert Fence.stale?(error),
           "the survivor absorbed another device's identifiers; work pinned before " <>
             "that must not write as though nothing happened"
  end

  # Task 3.5, the blocking prerequisite. DeviceCorrelation.explicit_device_uid used
  # to return any "sr:" uid verbatim with no lookup, which made the system's one
  # designated re-resolution point a no-op for the only uid format in production.
  test "a merged-away uid now resolves to the survivor instead of itself", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    resolved = DeviceCorrelation.resolve(%{device_uid: source.uid})

    assert resolved == survivor.uid,
           "a producer holding the pre-merge uid must be re-pointed at the survivor, " <>
             "not handed back the dead identity"
  end

  test "a live uid still resolves to itself", %{actor: actor} do
    {:ok, device} = create_device(actor)

    assert DeviceCorrelation.resolve(%{device_uid: device.uid}) ==
             device.uid
  end

  test "stale?/1 does not mistake an ordinary error for a superseded pin" do
    refute Fence.stale?(:some_other_failure)
    refute Fence.stale?(%{errors: []})
  end

  # Applies the pin the way a real consumer would: on the pending changeset, not
  # in an action-level filter, because Ash rebuilds atomic updates from a second
  # changeset and an action-level filter does not survive to constrain it.
  defp pinned_touch(device, pinned_revision, actor) do
    device
    |> Ash.Changeset.for_update(:touch, %{}, actor: actor)
    |> Fence.pin(pinned_revision)
    |> Ash.update(actor: actor)
  end

  defp revision(actor, uid) do
    {:ok, %Device{identity_revision: revision}} = Device.get_by_uid(uid, true, actor: actor)
    revision
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "fence-test",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  defp unique_ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    "10.#{a}.#{b}.#{rem(c, 254) + 1}"
  end
end
