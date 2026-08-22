defmodule ServiceRadar.Inventory.Identity.IdentityRevisionTest do
  @moduledoc """
  Behaviour of the device identity fence's monotonic counter.

  The counter exists so in-flight work can pin a value at resolution time and
  detect that its identity decision went stale. Two properties make it a fence
  rather than decoration, and both are asserted here:

    * it cannot lose a concurrent increment, and
    * it does NOT move for writes that leave identity unchanged.

  The second is why this is a dedicated column rather than an Ash
  `optimistic_lock`: `Device` takes high-frequency non-identity writes through
  `:touch`, `:set_availability` and `:gateway_sync`, and a counter that moved on
  those would make every pinned read stale within seconds.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.TestSupport

  require Ash.Query

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:identity_revision_test)}
  end

  test "a new device starts at revision 1", %{actor: actor} do
    {:ok, device} = create_device(actor)
    assert device.identity_revision == 1
  end

  test "bumping increments the revision", %{actor: actor} do
    {:ok, device} = create_device(actor)

    {:ok, bumped} = Device.bump_identity_revision(device, actor: actor)
    assert bumped.identity_revision == device.identity_revision + 1

    {:ok, again} = Device.bump_identity_revision(bumped, actor: actor)
    assert again.identity_revision == device.identity_revision + 2
  end

  test "the revision never decreases across repeated bumps", %{actor: actor} do
    {:ok, device} = create_device(actor)

    final =
      Enum.reduce(1..5, device, fn _i, acc ->
        {:ok, next} = Device.bump_identity_revision(acc, actor: actor)
        assert next.identity_revision > acc.identity_revision
        next
      end)

    assert final.identity_revision == 6
  end

  test "a non-identity write does not move the revision", %{actor: actor} do
    {:ok, device} = create_device(actor)
    before = device.identity_revision

    {:ok, touched} =
      device
      |> Ash.Changeset.for_update(:touch, %{}, actor: actor)
      |> Ash.update()

    assert touched.identity_revision == before

    {:ok, availability} =
      touched
      |> Ash.Changeset.for_update(:set_availability, %{is_available: false}, actor: actor)
      |> Ash.update()

    assert availability.identity_revision == before,
           "availability is not an identity transition and must not consume a revision"
  end

  # Read-modify-write in Elixir would lose one of these. The change module emits a
  # database expression precisely so it cannot.
  @tag sandbox: :unboxed
  test "concurrent bumps do not lose an increment" do
    actor = SystemActor.system(:identity_revision_test)
    {:ok, device} = create_device(actor)
    on_exit(fn -> destroy(device.uid) end)

    before = device.identity_revision
    concurrency = 8

    1..concurrency
    |> Task.async_stream(
      fn _ ->
        {:ok, fresh} = Device.get_by_uid(device.uid, false, actor: actor)
        Device.bump_identity_revision(fresh, actor: actor)
      end,
      max_concurrency: concurrency,
      timeout: 30_000
    )
    |> Stream.run()

    {:ok, reloaded} = Device.get_by_uid(device.uid, false, actor: actor)

    assert reloaded.identity_revision == before + concurrency,
           "expected #{concurrency} increments from #{concurrency} concurrent bumps, " <>
             "got #{reloaded.identity_revision - before} - an increment was lost"
  end

  # These two actions ARE identity transitions, and they are what transitively
  # covers the merge source (tombstoned through :soft_delete) and the unmerge
  # from-device (restored through :restore).
  test "a soft delete bumps the revision", %{actor: actor} do
    {:ok, device} = create_device(actor)
    before = device.identity_revision

    {:ok, deleted} = Device.soft_delete(device, "merged", "identity_reconciler", actor: actor)

    assert deleted.identity_revision > before,
           "a tombstone means the uid stops naming a live thing - that is a transition"
  end

  # MergeEngine.recreate_device/3 restores through Ash.bulk_update/3 rather than
  # the code interface, because an atomic update built from the primary read
  # cannot see a tombstoned row. Assert the change runs under that path too.
  test "a bulk restore bumps the revision", %{actor: actor} do
    {:ok, device} = create_device(actor)
    {:ok, deleted} = Device.soft_delete(device, "merged", "identity_reconciler", actor: actor)
    before = deleted.identity_revision

    result =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^device.uid)
      |> Ash.bulk_update(:restore, %{},
        actor: actor,
        return_records?: true,
        return_errors?: true,
        strategy: [:atomic, :stream]
      )

    assert %Ash.BulkResult{status: :success, records: [restored | _]} = result

    assert restored.identity_revision > before,
           "restore must bump under bulk_update, which is how unmerge recreates the device"
  end

  defp create_device(actor) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      hostname: "identity-revision-test",
      ip: unique_ip()
    })
    |> Ash.create(actor: actor)
  end

  # ocsf_devices has a unique-active-IP index, and the unboxed concurrency test
  # commits its rows rather than rolling them back, so a counter that resets with
  # the VM collides on a re-run against the same database. Random bytes give a
  # fresh address every call.
  defp unique_ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    "10.#{a}.#{b}.#{rem(c, 254) + 1}"
  end

  defp destroy(uid) do
    actor = SystemActor.system(:identity_revision_test)

    case Device.get_by_uid(uid, true, actor: actor) do
      {:ok, device} -> Ash.destroy!(device, actor: actor, authorize?: false)
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end
