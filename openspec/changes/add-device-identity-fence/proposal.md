# Add a device identity fence

## Why

`platform.merge_audit` records that a merge happened — `event_id`, from/to device,
confidence, `created_at` — but nothing monotonic is attached to the device itself. There is
no value in-flight work can pin and later check to discover that its identity decision went
stale. Raised as #3828.

The device row has no such value either: `ocsf_devices` has no `lock_version`, no Ash
`update_timestamp`, no counter, no generation (`device.ex:444-702`). `modified_time` cannot
substitute — it is `timestamp(0)`, wall-clock, and not bumped by every mutation.

Worse, **a merge never writes to the surviving device at all**. `merge_engine.ex:229` reads
the survivor only to confirm it exists and discards the result; every write targets child
tables. Any fence built on "the survivor changed" has nothing to observe: no timestamp
moves, no trigger fires, no CDC event on `ocsf_devices`.

The one forward-follow in the system, `Resolver.follow_canonical_device_id/2`, is reachable
from three call sites, none of them a write path holding a device id. The helper that looks
like it re-resolves before a write — `DeviceCorrelation.explicit_device_uid` — short-circuits
on `"sr:" <> _` and returns the uid verbatim with no existence check
(`device_correlation.ex:219-233`). Every canonical uid is `sr:<uuid>`, so that guard is a
no-op in production.

There is also no merge event on any bus. `MergeAudit` has no notifier, nothing publishes to
JetStream, and the only PubSub signal is a generic Device update carrying no `to_device_id`.
Fencing cannot be added at the messaging layer; it has to be a value the in-flight work
already pinned.

### Proven consequences today

- **Interface threshold monitoring stops permanently and silently.** The merge reassigns
  `Interface` rows but not `InterfaceSettings` (identity `[:device_id, :interface_uid]`);
  `InterfaceThresholdWorker` keeps querying the stale `device_id` and completes successfully
  against an empty result set forever.
- **Stateful alerts double-page, then hang open.** State is keyed on an interpolated string
  `"device_id=sr:<A>"` with no FK, absent from the merge's resource list. Engine-fired alerts
  carry `device_uid: nil`, so `reassign_alerts` structurally cannot see them.
- **Endpoint inventory reverses the merge.** `build_context/5` prefers the agent's cached
  stale uid over the freshly repointed value, so the next scan undoes `EndpointInventoryMoves`.
- **AWX runs keep targeting the dead identity** behind a RESTRICT FK that never fires,
  because the merge soft-deletes.

## What Changes

- **ADD** `platform.ocsf_devices.identity_revision`, a monotonic `bigint` bumped on every
  identity transition — merge, unmerge, split, alias invalidation, identifier reassignment,
  soft delete and restore. Named `identity_revision`, **not** `identity_version`: that name
  is already taken by the virtualization-v3 identity *schema* version.
- **ADD** a pinned-revision contract: a resolver that returns `{uid, identity_revision}`
  together, a compare-and-set check at write time, and a defined staleness policy
  (re-resolve once, then drop with telemetry — never raise, never silently discard).
- **ADD** an identity-transition event so caches and subscribers can react. `MergeAudit`
  gains a notifier and the transition is published; today nothing anywhere says "A folded
  into B".
- **MODIFY** merge to bump the survivor as well as the source, so the fence has something to
  observe on B.
- **FIX** the episode duplicate-and-false-resolve bug, which is real but is **not** caused by
  what was originally assumed. Tracing the question closed: the edge never re-identifies after
  a merge — `MetricResource.device_id` has zero production writers, so the agent always
  identifies from a local hostname, a polled target IP, or its agent id. `episode_uid` is
  therefore merge-stable and continuation already works. The actual defect is that core
  recomputes `finding_uid` from the canonical device but the upsert never writes it back
  (`anomaly_episode_registry.ex:175-193`, `anomaly_episode.ex:39`), leaving a row whose
  `device_uid` and `series_key` are post-merge and whose `finding_uid` is pre-merge. That
  disables both fold arms of the matching CTE, so the next edge-side episode restart inserts a
  duplicate and the original is closed as "resolved". One field in the conflict branch.
- **ADD** finding lineage recorded **by ingest when a re-key is observed** — not by the merge
  on a prediction — so findings written under the previous hash stay joinable after the
  correction.
- **ADD** a repair path for rows already stranded by past merges. A fence prevents new stale
  writes and repairs nothing; roughly 43 of 53 device-keyed tables are stranded by design
  today.
- **ADD** the two missing `merge_audit` indexes. The table has carried only its primary key
  since creation, so every chain walk and cooldown probe sequentially scans it.

## Impact

- Affected specs: `device-identity-reconciliation`, `anomaly-detection`
- Affected code: `inventory/identity/**`, `inventory/remediation/**`,
  `event_writer/device_correlation.ex`, `observability/anomaly_*`, `edge/agent_gateway_sync.ex`,
  `composite_checks/refresh_worker.ex`, plus the pinned write paths listed in `tasks.md`
- Migrations: one additive column with a default, two concurrent indexes, one lineage table
- Rollout is staged: the fence lands **observe-only** (pin, compare, emit telemetry, enforce
  nothing) and is enforced per pipeline only where telemetry shows real collisions
- Prerequisite: #3831 (partial merges must roll back before any state-derived fence is sound)
