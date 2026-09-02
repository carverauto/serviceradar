defmodule ServiceRadar.Inventory.Identity.MergeIdentityRevisionTest do
  @moduledoc """
  The identity fence across a merge and an unmerge.

  A merge changes the identity composition of BOTH devices: the source stops
  naming a live thing, and the survivor gains the source's identifiers. Before
  this, a merge wrote nothing at all to the survivor -- `merge_engine.ex` read it
  only to confirm it existed -- so nothing downstream could observe that the
  survivor had changed.

  The counts matter as much as the direction. A bump per reassigned identifier
  would be N writes describing one transition, so these tests assert the survivor
  moves by exactly one regardless of how many identifiers moved.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:merge_identity_revision_test)}
  end

  test "a merge bumps the survivor exactly once, whatever the identifier count", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)

    # Three identifiers move in one merge. The survivor must move by one, not three.
    for _ <- 1..3, do: register_mac(actor, source.uid)

    survivor_before = revision(actor, survivor.uid)

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    assert revision(actor, survivor.uid) == survivor_before + 1,
           "the survivor gained identifiers, so its revision moves - once per merge, " <>
             "not once per identifier"
  end

  test "a merge bumps the merged-away source", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)
    source_before = source.identity_revision

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    assert revision(actor, source.uid, include_deleted: true) > source_before,
           "the source is tombstoned through :soft_delete, which carries the bump"
  end

  # This is the property the whole fence exists for.
  test "a revision pinned before a merge no longer matches after it", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)

    pinned = revision(actor, survivor.uid)

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    refute revision(actor, survivor.uid) == pinned,
           "in-flight work holding this pin must be able to detect it went stale"
  end

  test "automatic merge cannot combine disjoint Armis source IDs", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)
    source_id = Ecto.UUID.generate()

    register_armis_id(actor, survivor.uid, "armis-survivor", source_id)
    register_armis_id(actor, source.uid, "armis-source", source_id)

    assert {:error, {:merge_blocked, :source_authority_conflict}} =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict"
             )

    assert {:ok, %Device{deleted_at: nil}} = Device.get_by_uid(source.uid, false, actor: actor)
    assert armis_owner(actor, "armis-source") == source.uid
    assert armis_owner(actor, "armis-survivor") == survivor.uid
  end

  test "an unmerge bumps both devices", %{actor: actor} do
    {:ok, survivor} = create_device(actor)
    {:ok, source} = create_device(actor)
    mac = register_mac(actor, source.uid)

    assert :ok =
             IdentityReconciler.merge_devices(source.uid, survivor.uid,
               actor: actor,
               reason: "identifier_conflict",
               details: %{identifiers: [%{type: :mac, value: mac}]}
             )

    survivor_after_merge = revision(actor, survivor.uid)
    source_after_merge = revision(actor, source.uid, include_deleted: true)

    assert :ok = IdentityReconciler.unmerge_device(source.uid, actor: actor)

    assert revision(actor, survivor.uid) > survivor_after_merge,
           "the survivor gave identifiers back - that is a composition change"

    assert revision(actor, source.uid, include_deleted: true) > source_after_merge,
           "the source names a live thing again, via :restore"
  end

  defp revision(actor, uid, opts \\ []) do
    include_deleted = Keyword.get(opts, :include_deleted, false)

    {:ok, %Device{identity_revision: revision}} =
      Device.get_by_uid(uid, include_deleted, actor: actor)

    revision
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "merge-revision-test",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  defp register_mac(actor, device_uid) do
    mac = unique_mac()

    {:ok, _} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: device_uid,
        identifier_type: :mac,
        identifier_value: mac,
        partition: "default",
        source: "test"
      })
      |> Ash.create(actor: actor)

    mac
  end

  defp register_armis_id(actor, device_uid, armis_id, source_id) do
    DeviceIdentifier
    |> Ash.Changeset.for_create(:register, %{
      device_id: device_uid,
      identifier_type: :armis_device_id,
      identifier_value: armis_id,
      partition: "default",
      source: "armis",
      metadata: %{"sync_service_id" => source_id}
    })
    |> Ash.create!(actor: actor)
  end

  defp armis_owner(actor, armis_id) do
    DeviceIdentifier
    |> Ash.Query.for_read(:lookup, %{
      identifier_type: :armis_device_id,
      identifier_value: armis_id,
      partition: "default"
    })
    |> Ash.read_one!(actor: actor)
    |> Map.fetch!(:device_id)
  end

  defp unique_ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    "10.#{a}.#{b}.#{rem(c, 254) + 1}"
  end

  defp unique_mac do
    6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :upper)
  end
end
