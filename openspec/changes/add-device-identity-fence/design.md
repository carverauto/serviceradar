# Design: Device identity fence

## Context

Issue #3828. The investigation behind this design is recorded in the issue thread; the
load-bearing findings are cited inline below. Two constraints shape every decision:

1. **A merge writes nothing to the surviving device.** `merge_engine.ex:229` reads B for an
   existence check and discards it. So a fence cannot be derived from observing B — the
   revision has to be written deliberately, on both sides.
2. **`Ash.transaction/3` committed partial merges** (fixed in #3831). Any state-derived
   fence is unsound while a half-merged device can exist, which is why that lands first.

## Goals / Non-Goals

**Goals**

- A monotonic value on the device that in-flight work can pin and check.
- Detect a stale identity decision at write time on the paths that matter.
- Stop a merge from silently splitting one logical anomaly into two episodes.
- Repair rows stranded by past merges.

**Non-Goals**

- Reassigning every device-keyed table. Roughly 43 of 53 are unreassigned; making all of
  them move is a separate, larger project and for hashed identities it is impossible.
- Distributed consensus or a general fencing-token protocol. This is one column and a
  compare-and-set on the paths that need it.
- Anything that depends on the ontology decision. This is deliberately independent of it.

## Decisions

### D1: The revision lives on `ocsf_devices`, not on `merge_audit`

`merge_audit` is an event log. In-flight work holds a *device id*, so the value it pins must
be reachable from that id in one read. A revision on the audit table would require a chain
walk per check, on a table that has only a primary key.

`identity_revision :bigint NOT NULL DEFAULT 1`. `ADD COLUMN ... NOT NULL DEFAULT` is
catalog-only on modern PostgreSQL, so no table rewrite. `NOT NULL` matters beyond tidiness:
with a nullable column, `NULL + 1 = NULL` and a NULL revision silently matches nothing,
which is a fence that fails open.

### D2: A dedicated bump action, not Ash `optimistic_lock`

Ash's `optimistic_lock/1` is in-repo precedent (`automation_callback_command_attempt.ex:351`)
but bumps on **every** update. `Device` takes high-frequency non-identity writes via `:touch`,
`:gateway_sync` and `:set_availability`; a lock version would churn constantly and the fence
would fire on writes that changed nothing about identity. This must be an *identity*
revision with its own action.

`Device :bump_identity_revision` implements `atomic/3` returning
`{:atomic, %{identity_revision: expr(^atomic_ref(:identity_revision) + 1)}}`. Never
`require_atomic? false` — that is a project hard rule and here it would also be wrong, since
two concurrent transitions must not lose a bump.

Not a database trigger: two of the transition sites (alias invalidation, soft delete) touch
no child table a trigger could hang off, so a trigger would have to span three tables and
would still miss them.

### D3: Both sides of a merge bump

The survivor bump is a **new** write — `merge_engine.ex:229` only reads B today. Without it,
work pinned to B cannot detect that B's identity composition changed underneath it, which is
the case that matters once B has absorbed A's identifiers.

### D4: Widen the resolver rather than change it

`resolve_device_id/2` has roughly ten callers plus an Ash action (`device.ex:393-401`).
Changing its return type breaks all of them for no benefit. Add
`resolve_device_identity/2` returning `{uid, identity_revision}` alongside it, and migrate
call sites deliberately.

For writes to the device row, the check is this repo's existing compare-and-set idiom: an
`Ash.Changeset.filter(expr(identity_revision == ^pinned))` on the **pending caller
changeset** (precedent: `secure_execution_lifecycle_ash_actions.ex:40-43`). The loser gets
`Ash.Error.Changes.StaleRecord`, which this repo already pattern-matches as a value
(`agent_gateway_sync.ex:1278-1280`).

### D5: Staleness policy is re-resolve once, then drop with telemetry

Not raise: the highest-volume consumers (`event_writer/processors/metrics.ex`,
`processors/sweep.ex`, `sweep_results_ingestor.ex`) are batch pipelines where one raised
device kills the batch. Not silently drop: `Alert`, `AnomalyEpisode` and
`DeviceCompositeCheckResult` are state machines, and a dropped transition leaves an episode
open forever.

Two revision changes observed inside one write is a merge storm — a different bug. Count it
and stop rather than retrying indefinitely.

### D6: Observe-only first

The fence lands pinning, comparing and emitting telemetry while enforcing nothing. This is
reversible and buys a measured answer to "how often, and on which pipeline" before spending
the pinning budget. Enforcement is per-pipeline and follows the telemetry.

A fence nobody checks is worse than no fence, because it reads as a guarantee. Two pinned
call sites prove the mechanism; roughly ten are needed before it stops being decoration.
That budget is part of this proposal, not a follow-up.

### D7: Episode lineage — because a hash cannot be reassigned

This is the hole a revision alone does not close, called out explicitly rather than left as
a caveat.

Episode identity is content-addressed on the device:
`finding_uid = anomaly:finding:2004:anomaly_detection:{device_uid}:{series_key}:{metric_class}`
and `episode_uid = sha256(finding_uid + episode_start)` (`verdict.rs:119-123`, `:593-597`).
A merge cannot rewrite either. Today `anomaly_episodes` is in neither the merge resource
list nor `reassignments.ex`, and `AnomalyEpisodeStaleCloseWorker` closes purely on
`last_seen_at` with no device awareness. So an open episode on A is orphaned; when the edge's
`resource.device_id` flips to B a **new** episode opens with a fresh baseline, and A's is
eventually marked `stale_closed` with `clear_reason: "stale"` — the operator is shown
"resolved" for a condition that never resolved.

That directly violates the existing requirement *One logical anomaly is one bounded episode
end-to-end*.

The design has two parts:

1. **Reassign the mutable column.** `anomaly_episodes.device_uid` is a plain `text` column
   distinct from the hashed `episode_uid`. Repointing it A -> B is safe and makes every
   device-scoped read follow the merge. The hash remains an opaque surrogate key; nothing
   requires it to be re-derivable.
2. **Record lineage so continuation is possible.** Core can reconstruct a `finding_uid` — the
   template is known and the only variable is the device uid. On merge, for each open episode
   on A, write `(old_finding_uid, new_finding_uid, episode_uid)` into
   `platform.anomaly_finding_lineage`. When a report arrives under `new_finding_uid` and an
   open lineage entry exists, ingest **continues that episode** rather than opening a new one.

If no report arrives under the successor within the staleness window, the episode is closed
with `clear_reason: "identity_merged"` — explicitly not `"stale"`, so the operator is never
told a condition resolved when what actually happened is that its device was merged away.

**Deliberately not doing:** changing the uid scheme to a merge-stable device lineage id. That
is the "correct" fix and it is a breaking change to an edge-computed identity with an
agent-side rollout, for a problem the lineage table solves at core with no ABI change.

### D8: Repair for already-stranded rows

A fence prevents new stale writes and repairs nothing. This addresses the existing damage.

`IdentityStrandedRowRepair`, a resumable Oban job:

- Walks `merge_audit` transitively to a terminal canonical device, with a depth cap and cycle
  detection (a per-pair merge cooldown exists, but the audit table can still contain chains).
- For each table in a **declared inventory** of device-keyed columns, repoints rows whose
  device reference is a merged-away tombstone.
- Batched by keyset with a bounded batch size, idempotent, and safe to re-run.
- **Dry-run first**: produces a per-table report of what it would change, and does nothing
  until explicitly run in apply mode.

The inventory is explicit rather than reflective. A reflective sweep over every column named
`device_id` would eventually repoint a column that is deliberately historical, and the tables
here differ: some must move, some must be left alone (timeseries rows are deliberately not
re-keyed), and some cannot move (hashed episode identities — those go through D7 instead).

**Rate limiting is mandatory, not optional.** This job rewrites rows across dozens of tables,
which is exactly the shape that produced the WAL saturation in #3829: a bulk rewrite whose
per-row cost was invisible until the database was checkpointing every ten seconds. The job
declares a batch size and an inter-batch pause, and the repair spec requires it to be
runnable without degrading foreground traffic.

### D9: `merge_audit` gets its missing indexes

`(from_device_id, created_at)` and `(to_device_id)`, created concurrently. The table has had
only its primary key since `rebuild_schema.exs:331-340`, so `latest_merge_target/2`, the
cooldown probe, and every chain walk added by D8 sequentially scan it. Not scope creep —
D7 and D8 both walk this table, and shipping them onto an unindexed table is how a repair job
becomes an outage.

## Risks / Trade-offs

- **The fence is detection, not mutual exclusion, for child-table writers**, until the merge
  takes `SELECT ... FOR UPDATE` on both device rows (the pattern `ArmisUnmerge` already uses
  at `armis_unmerge.ex:719-737`). Adding it needs deadlock analysis against that module's
  existing barrier, so it is gated on observe-only telemetry showing real collisions.
- **Enforcement converts silent misattribution into visible rejected writes** on the ~43
  stranded tables. That is probably an improvement, but it is a behaviour change with a
  per-pipeline policy decision attached, not a free win. Hence D6.
- **The repair job rewrites a lot of rows.** See D8; this is why it is dry-run-first and
  rate-limited.
- **Demo telemetry is not fully trustworthy for identity signals** — `armis_unmerge.ex:42-49`
  records that faker data makes some of them unreliable. Read observe-only results with that
  in mind.

## Migration Plan

1. #3831 (rollback partial merges) — prerequisite, already open.
2. Additive migration: column, two indexes, lineage table. No backfill; the default is 1.
3. Bump sites, then the resolver, then observe-only pinning on two paths.
4. Measure. Extend pinning to the remaining paths.
5. Episode lineage.
6. Repair job, dry-run reviewed before any apply run.

Each step is independently revertible; nothing before step 4 changes behaviour.

## Open Questions

- Does the agent-side `resource.device_id` actually flip to the survivor after a merge, and
  how quickly? This was **inferred, not proven** during investigation — agent-side resource
  population was not traced. It determines whether D7's continuation path is the common case
  or the rare one. Resolve before implementing D7.
- Should `identity_revision` survive an unmerge, or reset? Proposal: survive and keep
  incrementing. An unmerge is another transition, and a monotonic value that can go backwards
  is not a fence.
