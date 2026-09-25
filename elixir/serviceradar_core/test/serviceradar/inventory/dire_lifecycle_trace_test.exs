defmodule ServiceRadar.Inventory.DireLifecycleTraceTest do
  @moduledoc """
  Trace validation for `formal/dire/DireLifecycle.tla`.

  Each test drives the real lifecycle entry points (ingest, merge, unmerge, soft delete, sweep
  restore, agent check-in, purge) step by step through `ServiceRadar.DireLifecycleTrace`, and
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

  # The lifecycle defect switches today's code still has (formal/dire/README.md).
  @current_bugs [
    "fence_observe_only",
    "gateway_sync_no_bump",
    "purge_forgets_redirect",
    "sweep_restores_merged",
    "unmerge_restores_matches"
  ]

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:dire_lifecycle_trace_test)}
  end

  defp world(devices, ids, ips), do: %{devices: devices, ids: ids, ips: ips, bugs: @current_bugs}

  # #4619: a conflict merge records both sides' matches, and unmerge moves back every
  # identifier those matches name -- including the survivor's own.
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
    |> Trace.assert_golden!(demonstrates: "unmerge_restores_matches", tamper: true)
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

  # #4617: a sweep that finds a merged-away device's old address restores it.
  test "sweep_restores_merged", %{actor: actor} do
    "sweep_restores_merged"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :src, "i2" => :mac}, ["p1", "p2"]), actor)
    |> Trace.armis("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.merge("d1", "d2", :auto)
    |> Trace.sweep("p1")
    |> Trace.assert_golden!(demonstrates: "sweep_restores_merged")
  end

  # #4615: an agent check-in clears its device's tombstone.
  test "gateway_sync_revival", %{actor: actor} do
    "gateway_sync_revival"
    |> Trace.start(world(["d1"], %{"i1" => :agent}, ["p1"]), actor)
    |> Trace.agent("i1", "p1")
    |> Trace.soft_delete("d1")
    |> Trace.agent("i1", "p1")
    |> Trace.assert_golden!(demonstrates: "gateway_sync_no_bump")
  end

  # #4620: once a merged-away device is purged, a source still carrying its uid re-creates it.
  test "purge_recreate", %{actor: actor} do
    "purge_recreate"
    |> Trace.start(world(["d1", "d2"], %{"i1" => :mac, "i2" => :mac}, ["p1", "p2", "p3"]), actor)
    |> Trace.census("i1", "p1")
    |> Trace.census("i2", "p2")
    |> Trace.merge("d1", "d2", :auto)
    |> Trace.purge("d1")
    |> Trace.by_uid("d1", "p3")
    |> Trace.assert_golden!(demonstrates: "purge_forgets_redirect")
  end
end
