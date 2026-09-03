## Context

Everything the issue asks about is one of three things: already queryable,
persisted but unexposed, or not persisted at all. Sorting the acceptance
criteria into those buckets is what determines the shape of this change.

| Issue asks for | State today | Where |
|---|---|---|
| Tombstoned devices with `deleted_at` / `deleted_by` / `deleted_reason` | **Already queryable.** `in:devices deleted:true`; all three columns projected | `query/devices/filters.rs`, `models/inventory.rs` |
| Merge audit records | Table exists, indexed both directions; no entity | `platform.merge_audit` |
| Revival audit records | Table + trigger exist, indexed; no entity | `platform.device_revival_audit` |
| Identifier ownership | Table exists, 12M+ rows on demo; no entity | `platform.device_identifiers` |
| Canonical merge chain | Walked in Elixir only | `Identity.Resolver.latest_merge_target/2` |
| Run summaries, cap reached | **Not persisted.** Built, logged, discarded | `duplicate_sweep.ex`, `job_schedule.ex` |
| Evidence edges, blocked components | **Not persisted.** In-memory, one `Logger.warning` + telemetry | `report_blocked_components/1` |

Indexes that already exist and that this design commits to using:

- `merge_audit_from_device_created_idx` on `(from_device_id, created_at)`
- `merge_audit_to_device_idx` on `(to_device_id)`
- `device_revival_audit` on `(device_uid, revived_at)` and `(revived_at)`
- `device_identifiers_unique_identifier_index` on
  `(identifier_type, identifier_value, partition)`
- `device_identifiers_device_type_idx` on `(device_id, identifier_type)`

Those five cover every seed and every hop of both recursive walks below. This
change adds no index to an existing table.

## Goals / Non-Goals

Goals:

- Meet all six acceptance criteria from issue #4229 through SRQL and MCP alone.
- Add exactly one table and one writer. Everything else is read-only.
- Keep one data path: MCP tools compose bound SRQL, so the RBAC gate and the
  redaction rules are written once and covered by the injection regression
  tests the `mcp` spec already requires.
- Never let a diagnostic write fail the thing it is diagnosing.

Non-goals: changing merge behavior, mutating tools, snapshotting evidence per
run, a new RBAC key, a new UI page.

## Decisions

### Decision: Five entities, one of them a derived edge grain

Four entities map 1:1 onto tables. The fifth does not, because an evidence edge
is a *pair* of devices plus the identifier they share -- a different grain from
an identifier row, and squeezing it into `in:device_identifiers` would make the
result set mean two things depending on which filters were present.

| Canonical `in:` | Aliases | Backing |
|---|---|---|
| `merge_audit` | `device_merges`, `merges` | `platform.merge_audit` |
| `device_revival_audit` | `device_revivals`, `revivals` | `platform.device_revival_audit` |
| `device_identifiers` | `identifiers`, `device_identity` | `platform.device_identifiers` + owner join |
| `identity_reconciliation_runs` | `reconciliation_runs`, `dire_runs` | new table |
| `identity_evidence_edges` | `identity_evidence`, `evidence_edges` | derived from `device_identifiers` |

`identity_evidence_edges` is not an alias of `device_identifiers`, and
`merges` is not an alias of `merge_audit` in the sense of a table -- callers who
want device rows still use `in:devices`.

### Decision: The merge chain is a recursive CTE keyed by `chain:`

`in:merge_audit chain:<device_uid>` walks both directions from the seed:

- forward (`from_device_id = seed`, then the row's `to_device_id` as the next
  seed) answers "where did this device end up"
- backward (`to_device_id = seed`) answers "what was merged into this device"

Projection adds `depth` (hops from the seed) and `direction`
(`merged_into` | `merged_from`). Rows with `reason = 'unmerge'` are excluded
unless `include_unmerge:true`, matching `MergeAudit`'s own `:merged_from` and
`:merged_to` read actions.

Bounds, because a recursive CTE over a cyclic graph is a way to hang a
database: a `UNION` (not `UNION ALL`) on visited device ids, a hard depth cap
(default 32, configurable), and the standard SRQL `LIMIT`. A chain truncated by
the depth cap sets `truncated: true` in the result rather than silently
returning a partial chain that looks complete. Oscillating merge pairs are a
documented live condition, not a hypothetical -- see
`refactor-device-identity-reconciliation`, which records pairs re-merged 18-22
times.

### Decision: Evidence edges are derived, and a seed filter is mandatory

`in:identity_evidence_edges device:<uid>` expands the connected component by
self-joining `device_identifiers` on `(identifier_type, identifier_value,
partition)` where the two `device_id`s differ. Each row is one edge:

`device_a`, `device_b`, `identifier_type`, `identifier_value`, `partition_a`,
`partition_b`, `confidence`, `depth`, `direct`, `cross_partition`.

- `direct` is true when the edge is incident to the seed device. That is the
  distinction issue #4229 asks for: direct evidence versus mere transitive
  connectivity. It is what makes a 5-device blocked component legible -- the
  sweep refuses it precisely because vertices in it share no direct evidence
  (`duplicate_sweep.ex` moduledoc).
- `cross_partition` is true when `partition_a <> partition_b`. That is
  acceptance criterion 4.
- `identifier_value` is subject to the same redaction allowlist as elsewhere;
  the value is the evidence, so it is projected, but `metadata` is not.

An unseeded `in:identity_evidence_edges` is a self-join of a 12M-row table and
SHALL return a typed invalid-request error, not a slow success. This mirrors the
rule `add-srql-advisory-cpe-entities` adopted for unfiltered coordinate
aggregation. The same depth cap and `UNION`-on-visited bound as the merge chain
apply.

### Decision: `matches_current_facts` is computed in the query, not stored

`in:device_identifiers` joins `ocsf_devices` on `device_id = uid` and projects:

- `matches_current_facts` -- the identifier value equals the owner's current
  `mac`, `hostname`, `agent_id`, or `ip` for the corresponding
  `identifier_type`, or appears among the owner's `discovered_interfaces` MACs
- `owner_deleted`, `owner_deleted_at`, `owner_deleted_by`, `owner_deleted_reason`
- `owner_hostname`, `owner_ip`, `owner_partition`

The alternative, a persisted `corroborated_at` maintained by the registrar, is
cheaper to read and is the wrong change: it edits the write path of the
highest-volume table in the identity system to serve a diagnostic. Computing it
per row is affordable because `LIMIT` is applied before the join and both sides
are keyed on indexed columns.

A bare `value:` with no `type:` expands to
`identifier_type = ANY(<the seven enum values>)`, so the query still uses the
leading column of `device_identifiers_unique_identifier_index` instead of
seq-scanning 12M rows. The enum is closed (`agent_id`, `armis_device_id`,
`integration_id`, `netbox_device_id`, `hardware_serial`, `mac`, and the
remaining declared types in `DeviceIdentifier`), so the expansion is bounded and
needs no new index.

### Decision: One new table, `platform.identity_reconciliation_runs`

Columns:

| Column | Source |
|---|---|
| `run_id` (uuid, pk), `started_at`, `completed_at`, `duration_ms` | run |
| `status` (`completed` \| `failed`), `error_summary` | run, incl. the `rescue` path |
| `duplicate_identifier_count`, `duplicate_components`, `mergeable_components`, `blocked_components`, `blocked_devices`, `merges`, `errors` | existing stats map |
| `max_merges_configured`, `merge_cap_reached` | **new**; the cap is normalized then used only inside the reduce |
| `largest_blocked_component` | **new**; computed in `report_blocked_components/1` and currently discarded |
| `blocked_component_devices` (jsonb) | device-uid arrays per blocked component, capped |
| `trigger` (`scheduled` \| `manual`), `job_schedule_id` | caller |

Indexed on `(started_at DESC)` and on `(status, started_at DESC)`.

`blocked_component_devices` stores *membership only*. The edges are derived at
query time by `in:identity_evidence_edges`, which keeps them consistent with the
identifiers they describe. A snapshot would answer "what did the sweep believe
on Tuesday" at the cost of drifting from current identifier state and writing N
rows per component per run; membership plus live edges answers the operator's
actual question ("why is this component blocked, and is it still blocked").

### Decision: Three constraints on the writer, each with a precedent

1. **Write the row on the `rescue` path.** `reconcile_duplicates/1` currently
   swallows an exception into `{:error, error}` and persists nothing, so a
   crashed run is invisible in exactly the case where the operator most needs to
   see it. Status `failed` plus `error_summary` plus whatever counters were
   established before the raise.

2. **A failed run-row write never fails the sweep.** Wrap it so an error is
   logged and swallowed. This is the reasoning the revival-audit migration
   already wrote down: an audit that can reject the operation gives somebody a
   motive to switch it off, and the bypass becomes the default.

3. **Prune on completion.** Delete rows older than a configurable window
   (default 30 days) at the end of each run. At the current cadence this is a
   few hundred rows a day, which is small -- and unbounded growth in a
   diagnostics table is how a diagnostic becomes an incident.

`report_blocked_components/1` must return the largest component size rather than
`:ok`. Its `[]` clause returns `0`.

### Decision: MCP tools compose bound SRQL

Two Ash actions in `ServiceRadarWebNG.Mcp.Tools`, both running through
`Mcp.Runner` the way `execute_srql` does:

- **`trace_device_identity`** takes `uid`, `ip`, or `hostname`. It resolves a
  non-uid seed with a bound `in:devices` query that includes tombstones, then
  returns the device row with its tombstone fields, the merge chain in both
  directions, revival events, identifiers with `matches_current_facts`, and the
  evidence component with its `cross_partition` flag. Covers criteria 1, 2, 3, 6.
- **`explain_identity_reconciliation`** takes `run_id` or a time range and
  returns run summaries including `merge_cap_reached`, the blocked components
  with their device lists, and on request the evidence edges for one named
  component. Covers criteria 4, 5.

Every scalar argument is bound, never concatenated into an SRQL fragment -- the
`mcp` spec already requires this and already has regression tests for it. The
alternative, calling `ServiceRadar.Inventory` resources directly, would give
web-ng a second data path into core identity internals that re-implements
redaction and skips the `EntityAccess` gate.

### Decision: RBAC is `devices.view`, and the passthrough is the real risk

All five entities and every alias go into the `"devices.view"` list in
`SRQL.EntityAccess`. No new catalog key: these are device-scoped inventory
diagnostics, the same dataset a viewer can already reach through
`in:devices deleted:true`, and a new key would need catalog entries, role-profile
seeding, and a migration for existing roles to buy very little.

The hazard is not the key, it is `permission_for_query/1`, which returns
`:passthrough` for unknown entities so the compiler stays the source of that
error. The moment the Rust parser accepts `in:merge_audit`, any alias missing
from the map is an **ungated** entity on the HTTP and MCP paths, and it fails
open silently. This change therefore carries a test asserting that every parser
alias for the five entities resolves to `{:ok, "devices.view"}` and not
`:passthrough`.

### Decision: Redaction is a key allowlist, not whole-object projection

`merge_audit.details` is free-form jsonb written by several callers, and
`device_identifiers.metadata` likewise. Both are projected through an explicit
key allowlist; unknown keys are dropped rather than passed through. `deleted_by`
and `previous_deleted_by` name an actor and are projected -- they are the point
of the audit -- but they are the only actor fields exposed.

## Risks / Trade-offs

- **Recursive CTEs on a graph with known cycles.** Mitigated by
  `UNION`-on-visited, a depth cap, an explicit `truncated` flag, and the
  standard `LIMIT`. Tested against a seeded oscillating pair, not just a clean
  chain.
- **`device_identifiers` is ~12M rows on demo.** Every access path is either
  seeded on `device_id` or uses the leading column of the unique index; the
  unseeded edge query is refused rather than served slowly.
- **`matches_current_facts` costs a join per returned row.** Bounded by `LIMIT`
  applied first. If this ever shows up in `pg_stat_statements`, the fix is a
  narrower default projection, not a denormalized column.
- **One new writer inside a scheduled job.** Constrained to never fail the
  sweep, which means a run row can in principle be missing. That is the correct
  trade: a missing diagnostic beats a blocked reconciliation.

## Migration Plan

1. Migration creating `platform.identity_reconciliation_runs` with its two
   indexes, `prefix: "platform"`. Ash resource with `migrate? false`, following
   the existing convention for named SQL migrations in this repo.
2. `DuplicateSweep` starts writing rows. No backfill is possible -- the historical
   runs exist only as log lines -- and none is attempted.
3. SRQL entities ship independently of the table; the four read-only entities
   are useful the moment they land. `in:identity_reconciliation_runs` returns an
   empty result until the first run after deploy, which is correct and
   distinguishable from an error.
4. No rollback coupling: dropping the table in `down/0` leaves the other four
   entities working.

## Open Questions

None blocking. Two deferred by decision rather than uncertainty: whether the
runs table eventually wants a CAGG rollup (not until someone asks for run
trends), and whether `identity_evidence_edges` should support `stats:count()`
group-by (deferred until a caller needs it; the seeded grain is small).
