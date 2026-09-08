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

### D7: Episodes — the edge never flips, and the real defect is a missing upsert field

The proposal originally assumed a merge causes the edge to start emitting under the
survivor's uid, splitting one logical anomaly into two episodes. **That was traced and is
false**, and the correction inverts the design.

`MetricResource.device_id` (proto field 9) has **zero production writers** anywhere in the
repo. None of the five envelope constructions in `go/pkg/agent/metric_envelope.go` sets it,
no Rust producer sets it, and the gateway's attestation rewrites five other fields and leaves
it alone. Core's own decoder says so in a comment: *"device_id is NULL for sysmon/SNMP/ICMP
because no producer/gateway/core sets resource.device_id"*
(`observability/metric_envelope.ex:58-62`). The only assignments are three test fixtures.

So `anomaly_device_uid` (`identity.rs:216-232`) always falls through to a locally-derived
value: the agent's `os.Hostname()` for sysmon, the polled target IP for SNMP, the agent id
for ICMP. **A merge changes none of them, and no config delivery can**, because none is
core-owned. Nothing — restart, config poll, re-registration, upgrade — makes the edge emit
under the survivor.

That is the world the original design feared most, and it is the world in which continuation
is **free**. Because the edge identity is merge-invariant, `episode_uid` is stable across a
merge, so the existing upsert already matches the open episode by `episode_uid` and
re-attributes it in place — same row, same `opened_at`, occurrence history intact, edge
detector state undisturbed. **Continuation needs no new mechanism.**

#### The actual defect

Core does *not* trust the edge's attribution: it re-resolves to the canonical device and
**recomputes** `finding_uid` from it. So a merge does change `finding_uid` — core-side.

But `finding_uid` is absent from the upsert's conflict branch
(`anomaly_episode_registry.ex:175-193` sets `device_uid` and `series_key` from `EXCLUDED` but
never `finding_uid`), and it is explicitly subtracted at `anomaly_episode.ex:39`
(`@episode_upsert_fields @episode_fields -- [:episode_uid, :finding_uid, :opened_at]`).

After a merge the surviving row therefore holds the **survivor's** `device_uid` and
`series_key` but the **pre-merge** `finding_uid`. That row is internally inconsistent, and
decisively: the `existing` CTE's two fold arms both match on `finding_uid = $2`
(`anomaly_episode_registry.ex:44-49`), so neither can ever match that row again. Only the
`episode_uid` arm still works.

That holds until the edge starts a **new** episode on the same series — checkpoint expiry
(~6h) or an agent restart. Then no arm matches, a **duplicate** episode is inserted, and the
original is eventually closed `stale_closed` / `clear_reason: "stale"`.

Which is precisely the symptom the original design described — an operator shown "resolved"
for a condition that never resolved — reached through a door it never looked at. The fix is
one field in the conflict branch, unconditionally: `EXCLUDED.finding_uid` is either identical
(a normal fold) or the newly canonical value (a merge), never a regression.

#### What lineage is actually for

The lineage table survives with a different writer and a different purpose. Rewriting
`finding_uid` in place orphans findings already written under the old hash — the mirror of
today's bug. So lineage is written **by ingest, on observation**, at the moment the upsert
sees an incoming `finding_uid` differing from the stored one, recording the previous and new
identities so historical rows stay joinable.

Lineage keyed on an *observation* is sound. Lineage keyed on a *prediction* about edge
behaviour — the original design — describes an event that never occurs, and a record that
looks like a guarantee but can never fire is worse than none.

#### A dependency this design now rests on

Core's resolution follows merges only **incidentally**: `DeviceCorrelation` never calls
`follow_canonical_device_id/2` and never reads `MergeAudit`. It lands on the survivor only
because the source device is tombstoned *and* its anchors were reassigned. Neither is
asserted as an invariant of the anomaly path and nothing tests it, so a future merge variant
that stops tombstoning would silently break continuation. This must be either hardened onto
the merge-aware resolver or written down and tested.

**Deliberately not doing:** projecting `Agent.device_uid` onto `MetricResource.device_id` to
reach a world where the edge does flip. It is independently motivated — the same gap already
breaks seasonal-baseline delivery for sysmon, since core keys baselines by canonical device
id while the edge derives `<hostname>|<metric>` — but done now it would be strictly worse.
The edge would emit `sr:` uids, which `DeviceCorrelation.explicit_device_uid` short-circuits
with no lookup, switching **off** the incidental merge-following that makes continuation work
today; and `episode_uid` would become merge-unstable, creating the very need for successor
lineage that this correction removes. It is deferred with its prerequisite attached (D10).

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

### D10: The `sr:` short-circuit is a blocking prerequisite, not a cleanup

`DeviceCorrelation.explicit_device_uid` returns any `"sr:" <> _` uid verbatim with no lookup
(`device_correlation.ex:219-233`). It is latent today only because nothing on the edge emits
an `sr:` uid. Any future work that delivers a canonical uid to the edge makes it live and
harmful in the same change.

Its fix must route through `Resolver.follow_canonical_device_id/2`, not merely add an
existence check: an existence check returns nil for a tombstoned device, and the anomaly path
then falls back through the correlation chain, which rescues candidates carrying an agent id
or IP but not ones anchored only on the uid.

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

## Resolved Questions

**Does the agent-side `resource.device_id` flip to the survivor after a merge?** No, and it
cannot. Traced end to end and independently confirmed: `MetricResource.device_id` has zero
production writers, so the edge always identifies from a locally-derived value that no merge
and no config delivery can change. There is no trigger and therefore no lineage TTL. See D7 —
this inverted the episode design rather than parameterising it, and it means continuation is
automatic rather than rare.

## Open Questions

- Can a merge transiently push an SNMP series onto the `{:withhold, ...}` drop path in
  `resolve_snmp_anomaly_device_uid`, where rows are discarded entirely? That is the one
  plausible way a merge could genuinely silence a producer and orphan an open episode. It is
  a test to run, not a conclusion — and it is what decides whether a distinct
  `identity_merged` clear reason is worth building at all.
- Is episode scope per series, or per series per detector? Core collapses the edge's
  detector-specific finding identities into one recomputed hash, so a drift episode can fold
  onto a spike episode's open row. This is independent of merges and needs an explicit
  position either way.
- Should `identity_revision` survive an unmerge, or reset? Proposal: survive and keep
  incrementing. An unmerge is another transition, and a monotonic value that can go backwards
  is not a fence.
