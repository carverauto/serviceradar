defmodule ServiceRadar.Inventory.DireLifecycleTraceTest do
  @moduledoc """
  Trace validation for `formal/dire/DireLifecycle.tla`.

  Each test drives the real lifecycle entry points (ingest, merge, unmerge, soft delete, sweep,
  expiry, agent check-in, purge) step by step through `ServiceRadar.DireLifecycleTrace`, and
  requires the recorded trace to equal the committed `formal/dire/traces/Trace_<name>.{tla,cfg}`.
  `//formal/dire` model-checks those files against the lifecycle model with the defect switches
  that match today's code. When the code changes behavior, the comparison here fails;
  regenerate with DIRE_TRACE_WRITE=1 on a scratch database and let the model check decide
  (formal/dire/README.md).
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.DireLifecycleTrace, as: Trace
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:dire_lifecycle_trace_test)}
  end

  defp world(devices, ids, ips), do: %{devices: devices, ids: ids, ips: ips}

  # #4619 (fixed): a conflict merge records both sides' matches; the unmerge gives back only
  # the identifiers the merged-away device owned, never the survivor's own. Kept as a
  # regression trace.
  # Steps: Armis device d1 (i1) and census device d2 (i2); the resolver then sees both
  # identifiers on one observation and merges the two (the code picks the survivor); then the
  # merged-away device is unmerged.
  test "conflict_unmerge", %{actor: actor} do
    "conflict_unmerge"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :src, "i2" => :mac}, ["p1", "p2"]), actor)
    |> Trace.armis("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.conflict(["i1", "i2"])
    |> Trace.unmerge(:latest)
    |> Trace.assert_golden!(tamper: true)
  end

  # #4614 (fixed): the next ingest that reaches a soft-deleted device writes it back to life,
  # and that revival bumps its identity_revision. Kept as a regression trace.
  test "soft_delete_upsert_revival", %{actor: actor} do
    "soft_delete_upsert_revival"
    |> Trace.start(world(["d1"], %{"i1" => :mac}, ["p1"]), actor)
    |> Trace.census("i1", "p1")
    |> Trace.soft_delete("d1")
    |> Trace.census("i1", "p1")
    |> Trace.assert_golden!()
  end

  # #4616 (fixed): after an automatic merge is undone and the device is deleted for another
  # reason, the old merge row no longer redirects it; a source carrying its uid reaches the
  # device itself. Kept as a regression trace.
  test "stale_redirect", %{actor: actor} do
    "stale_redirect"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :mac, "i2" => :mac}, ["p1", "p2", "p3"]), actor)
    |> Trace.census("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.merge("d1", "d2", :auto)
    |> Trace.unmerge("d1")
    |> Trace.soft_delete("d1")
    |> Trace.by_uid("d1", "p3")
    |> Trace.assert_golden!()
  end

  # #4617 (fixed): a sweep that finds a merged-away device's old address leaves it deleted.
  # The sweep still writes its sighting to the tombstone (SweepRefresh), which the defect
  # switch sweep_refreshes_expired_tombstone allows until add-source-id-succession D12 lands; a
  # regression that restores the device again would log SweepRestore and fail the comparison.
  # The knockout checks the trace without the switch, under which the model leaves the
  # tombstone alone (SweepSkip), and requires TLC to reject it.
  test "sweep_restores_merged", %{actor: actor} do
    "sweep_restores_merged"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :src, "i2" => :mac}, ["p1", "p2"]), actor)
    |> Trace.armis("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.merge("d1", "d2", :auto)
    |> Trace.sweep("p1")
    |> Trace.assert_golden!(demonstrates: "sweep_refreshes_expired_tombstone")
  end

  # #4615 (fixed): an agent check-in restores its soft-deleted device, and the restore bumps
  # its identity_revision. Kept as a regression trace.
  test "gateway_sync_revival", %{actor: actor} do
    "gateway_sync_revival"
    |> Trace.start(world(["d1"], %{"i1" => :agent}, ["p1"]), actor)
    |> Trace.agent("i1", "p1")
    |> Trace.soft_delete("d1")
    |> Trace.agent("i1", "p1")
    |> Trace.assert_golden!()
  end

  # #4620 (fixed): once a merged-away device is purged, a source still carrying its uid lands on
  # the survivor instead of re-creating it. Kept as a regression trace.
  test "purge_recreate", %{actor: actor} do
    "purge_recreate"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :mac, "i2" => :mac}, ["p1", "p2", "p3"]), actor)
    |> Trace.census("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.merge("d1", "d2", :auto)
    |> Trace.purge("d1")
    |> Trace.by_uid("d1", "p3")
    |> Trace.assert_golden!()
  end

  # #4603: a device the resolver seeded from its address alone holds no strong identifier, so
  # it expires once unseen past the window (the model's Expire, whose ExpiryKeepsStrongIdentity
  # property forbids expiring a device that owns an identifier). A sweep that finds it again
  # restores it through :restore, which bumps its revision. d1 holds a hardware MAC throughout.
  test "expire_ephemeral", %{actor: actor} do
    "expire_ephemeral"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :mac}, ["p1", "p2"]), actor)
    |> Trace.census("i1", "p1")
    |> Trace.address_only("p2")
    |> Trace.expire("d2")
    |> Trace.sweep("p2")
    |> Trace.assert_golden!()
  end

  # add-source-id-succession D12: a host only a sweep knows is seeded from its address, expires
  # once unseen past the window, and then answers a sweep again. The sweep finds its tombstone,
  # does not restore it (restore_eligible?/1 wants a discovery source other than the sweep) and
  # writes the sighting to it, so the host stays deleted. The knockout checks the trace without
  # the switch, under which the model restores the device, and requires TLC to reject it. The
  # identifier is never reported: the seed must not own one.
  test "expired_sweep_only_returns", %{actor: actor} do
    "expired_sweep_only_returns"
    |> Trace.start(world(["d1"], %{"i1" => :mac}, ["p1"]), actor)
    |> Trace.sweep("p1")
    |> Trace.expire("d1")
    |> Trace.sweep("p1")
    |> Trace.assert_golden!(demonstrates: "sweep_refreshes_expired_tombstone")
  end
end
