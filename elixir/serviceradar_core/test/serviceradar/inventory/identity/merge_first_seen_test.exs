defmodule ServiceRadar.Inventory.Identity.MergeFirstSeenTest do
  @moduledoc """
  A merge survivor's `first_seen_time` records how long the HOST has been known,
  not how long its surviving row has existed.

  The survivor is frequently the NEWER row. A passive census sighting of an
  address mints a device, and the reconciler only later recognises it as an
  already-known host and merges the older row into it. Before this,
  `preserve_survivor_attributes/2` carried tags, metadata, type and discovery
  sources across that merge but not `first_seen_time`, so the earlier date was
  discarded and the host reappeared on the "Recently added devices" report
  (`in:devices first_seen:last_30d`) months after it was found.

  Regression coverage for GitHub #4381.
  """

  use ServiceRadar.DataCase, async: true

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.IdentityReconciler
  alias ServiceRadar.Repo

  require Ash.Query

  @moduletag :integration

  # Far enough apart that `first_seen:last_30d` separates them, which is the
  # report the defect showed up on.
  @old ~U[2020-01-02 03:04:05Z]
  @recent ~U[2020-06-07 08:09:10Z]

  setup_all do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:merge_first_seen_test)}
  end

  test "a newer survivor inherits the merged-away device's earlier first_seen", %{actor: actor} do
    survivor = create_device(actor, @recent)
    source = create_device(actor, @old)

    merge!(source, survivor, actor)

    assert first_seen(actor, survivor) == @old,
           "first_seen records how long the HOST has been known, and the surviving " <>
             "row is younger than the host"
  end

  test "an older survivor keeps its own first_seen", %{actor: actor} do
    survivor = create_device(actor, @old)
    source = create_device(actor, @recent)

    merge!(source, survivor, actor)

    assert first_seen(actor, survivor) == @old,
           "a merge only ever moves first_seen earlier - it must never age a device forward"
  end

  test "a source with no first_seen leaves the survivor's date intact", %{actor: actor} do
    survivor = create_device(actor, @recent)
    source = create_device(actor, nil)

    merge!(source, survivor, actor)

    assert first_seen(actor, survivor) == @recent,
           "LEAST ignores NULLs; an undated source must not blank the survivor"
  end

  test "a survivor with no first_seen takes the source's date", %{actor: actor} do
    survivor = create_device(actor, nil)
    source = create_device(actor, @old)

    merge!(source, survivor, actor)

    assert first_seen(actor, survivor) == @old, "a known date is better than none"
  end

  defp merge!(source_uid, survivor_uid, actor) do
    assert :ok =
             IdentityReconciler.merge_devices(source_uid, survivor_uid,
               actor: actor,
               reason: "identifier_backfill"
             )
  end

  defp first_seen(actor, uid) do
    {:ok, %Device{first_seen_time: first_seen_time}} = Device.get_by_uid(uid, false, actor: actor)

    first_seen_time
  end

  # `:create` stamps `first_seen_time` when the caller omits it, so a device
  # that genuinely has none is written directly. That is the shape a survivor
  # can arrive in, and it is what makes LEAST's NULL handling load-bearing.
  defp create_device(actor, first_seen_time) do
    {:ok, device} =
      Device
      |> Ash.Changeset.for_create(:create, %{
        uid: "sr:" <> Ecto.UUID.generate(),
        hostname: "merge-first-seen-test",
        ip: unique_ip()
      })
      |> Ash.create(actor: actor)

    set_first_seen!(device.uid, first_seen_time)

    device.uid
  end

  defp set_first_seen!(uid, value) do
    {:ok, _} =
      Repo.query(
        "UPDATE platform.ocsf_devices SET first_seen_time = $1 WHERE uid = $2",
        [value && DateTime.to_naive(value), uid]
      )

    :ok
  end

  defp unique_ip do
    <<a, b, c>> = :crypto.strong_rand_bytes(3)
    "10.#{a}.#{b}.#{rem(c, 254) + 1}"
  end
end
