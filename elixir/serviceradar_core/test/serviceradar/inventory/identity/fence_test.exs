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

  describe "observe-only" do
    # The whole point of the observe-only stage is that it measures without
    # changing behaviour. If it ever refused a write, the rollout would be
    # enforcing before anyone had read the telemetry -- so this is the test that
    # matters most here.
    test "reports drift but still lets the write land", %{actor: actor} do
      {:ok, device} = create_device(actor)
      pinned = {device.uid, device.identity_revision}

      {:ok, _} = Device.bump_identity_revision(device, actor: actor)

      events = capture_fence_events(fn -> assert Fence.observe(pinned, :pilot) == :ok end)

      assert [{[:serviceradar, :identity_fence, :observed_drift], meta}] = events
      assert meta.pinned_revision == device.identity_revision
      assert meta.current_revision == device.identity_revision + 1

      # ...and the write is NOT refused, unlike pin/2.
      {:ok, reloaded} = Device.get_by_uid(device.uid, true, actor: actor)
      assert {:ok, _} = Ash.update(Ash.Changeset.for_update(reloaded, :touch, %{}, actor: actor))
    end

    test "reports fresh when the revision has not moved", %{actor: actor} do
      {:ok, device} = create_device(actor)

      events =
        capture_fence_events(fn ->
          assert Fence.observe({device.uid, device.identity_revision}, :pilot) == :ok
        end)

      assert [{[:serviceradar, :identity_fence, :observed_fresh], meta}] = events
      assert meta.current_revision == device.identity_revision
      assert meta.pipeline == :pilot
    end

    # A merge soft-deletes the source, so a pin held against it reads as gone
    # rather than as a moved revision. Distinguishing the two matters: drift means
    # re-resolve, missing means the pinned device is no longer there at all.
    test "reports missing when the pinned device was merged away", %{actor: actor} do
      {:ok, device} = create_device(actor)
      pinned = {device.uid, device.identity_revision}

      {:ok, _} =
        device
        |> Ash.Changeset.for_update(:soft_delete, %{}, actor: actor)
        |> Ash.update(actor: actor)

      events = capture_fence_events(fn -> assert Fence.observe(pinned, :pilot) == :ok end)

      assert [{[:serviceradar, :identity_fence, :observed_missing], meta}] = events
      assert meta.current_revision == nil
    end

    test "an unreadable pin is a no-op rather than an error" do
      assert Fence.observe_pin("sr:" <> Ecto.UUID.generate()) == :error
      assert Fence.observe(:error, :pilot) == :ok
      assert capture_fence_events(fn -> Fence.observe(:error, :pilot) end) == []
    end

    # enqueue_many/1 runs inside sweep ingestion and can carry thousands of uids,
    # so the batched read is what keeps this from adding a query per device.
    #
    # This does guard the read-shape trap: drop the `for_read/3` that supplies
    # `include_deleted` and the action's `is_nil(deleted_at) or ^arg(...)` filter
    # goes NULL, the query matches nothing, and these assertions go nil.
    #
    # It does NOT guard the batch cap. Device's read declares
    # `default_limit: 5000` and rejects `page: false`, so the limit has to be
    # sized to the batch; with two devices here, a regression to the default
    # would still pass. Verifying that needs 5000+ rows, which is not worth a
    # fixture -- the constraint is recorded at the call site instead.
    test "observe_pins/1 reads a batch and skips what it cannot see", %{actor: actor} do
      {:ok, a} = create_device(actor)
      {:ok, b} = create_device(actor)
      absent = "sr:" <> Ecto.UUID.generate()

      pins = Fence.observe_pins([a.uid, b.uid, absent])

      assert pins[a.uid] == a.identity_revision
      assert pins[b.uid] == b.identity_revision
      refute Map.has_key?(pins, absent)
      assert Fence.observe_pins([]) == %{}
    end
  end

  defp capture_fence_events(fun) do
    ref = make_ref()
    test_pid = self()

    events = [
      [:serviceradar, :identity_fence, :observed_fresh],
      [:serviceradar, :identity_fence, :observed_drift],
      [:serviceradar, :identity_fence, :observed_missing]
    ]

    handler_id = {__MODULE__, ref}

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, _measurements, meta, _config -> send(test_pid, {ref, event, meta}) end,
      nil
    )

    try do
      fun.()
      collect_fence_events(ref, [])
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_fence_events(ref, acc) do
    receive do
      {^ref, event, meta} -> collect_fence_events(ref, [{event, meta} | acc])
    after
      0 -> Enum.reverse(acc)
    end
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
