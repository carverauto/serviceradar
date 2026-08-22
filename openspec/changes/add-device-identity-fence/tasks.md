# Tasks

## 0. Prerequisite

- [x] 0.1 Land #3831 — `MergeEngine` must use `Ash.transact/3` so a failed merge rolls back.
      A state-derived fence is unsound while a half-merged device can exist.

## 1. Schema

- [x] 1.1 Migration: `ALTER TABLE platform.ocsf_devices ADD COLUMN identity_revision bigint
      NOT NULL DEFAULT 1`. Catalog-only on modern PostgreSQL; no backfill. Do **not** name it
      `identity_version` — that is the virtualization-v3 identity schema version.
- [x] 1.2 Same migration: `merge_audit` indexes `(from_device_id, created_at)` and
      `(to_device_id)`, `concurrently: true` with `@disable_ddl_transaction true` and
      `@disable_migration_lock true`. The table has had only its primary key since creation.
- [x] 1.3 Migration: `platform.anomaly_finding_lineage` — previous finding uid, new finding
      uid, episode uid, previous/new device uid, observed_at. Unique on
      `(previous_finding_uid, new_finding_uid)`, plus an index on `episode_uid`. **Not** unique
      on the previous finding uid alone: a device merged twice produces two hops and that
      constraint would reject the second. Rows are written by ingest when a re-key is
      observed, never by the merge on prediction (see design D7).
- [x] 1.4 Expose `identity_revision` on the `Device` Ash resource as a read-only attribute.

## 2. The bump

- [x] 2.1 `Device :bump_identity_revision` with an `atomic/3` callback returning
      `{:atomic, %{identity_revision: expr(^atomic_ref(:identity_revision) + 1)}}`.
      Never `require_atomic? false`.
- [x] 2.2 Unit tests: monotonic, atomic under concurrency, not bumped by `:touch`,
      `:gateway_sync` or `:set_availability`.
- [x] 2.3 Call it from every identity transition. All eight, not just the merge:
  - [x] 2.3.1 `merge_engine.ex` `do_merge_devices` — source **and** survivor. The survivor
        bump is a new write; `:229` only reads B today.
  - [x] 2.3.2 `merge_engine.ex` `do_unmerge` — both devices.
  - [x] 2.3.3 `alias_guard.ex` `invalidate_ip_alias`
  - [x] 2.3.4 `remediation/agent_links.ex`
  - [x] 2.3.5 `remediation/armis_unmerge.ex` (the split path)
  - [x] 2.3.6 `identity/registrar.ex` (both transition points)
  - [x] 2.3.7 `identity/reassignments.ex` — `DeviceIdentifier :reassign_device`
  - [x] 2.3.8 `device.ex` `:soft_delete` and `:restore`
- [x] 2.4 Integration test per transition type asserting the bump, including that an unmerge
      increments rather than restoring the previous value.

## 3. Pin and check

- [x] 3.1 Add `resolve_device_identity/2` returning `{uid, identity_revision}`. Do **not**
      change `resolve_device_id/2`'s return type — roughly ten callers plus an Ash action.
- [x] 3.2 Compare-and-set helper using `Ash.Changeset.filter(expr(identity_revision == ^pinned))`
      on the pending caller changeset, handling `Ash.Error.Changes.StaleRecord` as a value.
- [x] 3.3 Staleness policy helper: re-resolve once, retry once, then abandon and emit
      telemetry. Never raise; never drop silently. Abandon after two observed transitions.
- [x] 3.4 Telemetry events under `[:serviceradar, :identity_fence, ...]` carrying pipeline,
      device id, pinned revision and observed revision.
- [x] 3.5 **Fix the re-resolution no-op — BLOCKING PREREQUISITE for any edge-projection
      work** (see design D10). `DeviceCorrelation.explicit_device_uid`
      (`device_correlation.ex:219-233`) short-circuits on `"sr:" <> _` and returns the uid with
      no lookup, so it re-resolves nothing in production. Route it through
      `Resolver.follow_canonical_device_id/2` — **not** merely an existence check, which
      returns nil for a tombstoned device and drops the anomaly path into a correlation
      fallback that cannot rescue a candidate anchored only on the uid. Latent today only
      because nothing on the edge emits an `sr:` uid; it goes live and harmful the moment
      anything does.

## 4. Observe-only rollout

- [x] 4.1 Pin `edge/agent_gateway_sync.ex:285-320` — resolves identity once, then six
      independent writes. The clearest case.
- [x] 4.2 Pin `composite_checks/refresh_worker.ex` — an Oban job whose only argument is a
      device uid. The pinned revision goes in job args under a string key (Oban args are
      string-keyed).
- [x] 4.3 Ship both comparing and reporting only. Enforce nothing.
- [ ] 4.4 Run for a measured period and read the telemetry. Treat demo identity signals with
      care — `armis_unmerge.ex:42-49` records that faker data makes some unreliable.
- [ ] 4.5 Decide enforcement per pipeline from what the telemetry actually shows.

## 5. Extend pinning

Target roughly ten pinned paths total; below that the fence is decoration.

- [ ] 5.1 `sweep_jobs/sweep_results_ingestor.ex` -- **hazard found**: the bracket calls
      `restore_deleted_devices/2`, and `update :restore` carries `change BumpIdentityRevision`
      (device.ex:352), so the pipeline bumps revisions inside its own bracket. Pinning through
      the default read (`include_deleted: false`) excludes those devices automatically, the way
      `processors/sweep.ex` does; do NOT pin with `include_deleted: true`.
- [x] 5.2 `event_writer/processors/sweep.ex`
- [ ] 5.3 `event_writer/processors/metrics.ex` -- highest write volume of the set;
      `observe_many/2` emits one telemetry event per pinned device, so measure the emit cost
      before enabling here.
- [ ] ~~5.4 `core/result_processor.ex`~~ **drop this site.** The module performs ZERO writes
      (no Ash create/update/destroy/bulk, no Repo write) and has ZERO production callers --
      only `test/serviceradar/core/result_processor_test.exs` references it. A pin here would
      bracket nothing and report a constant zero, which is worse than no measurement because it
      reads as evidence of safety. Removing it means the target of ~10 pinned paths is met by
      the other sites plus the two pilots.
- [ ] 5.5 `inventory/endpoint_inventory_ingestor.ex` — also fix `build_context/5`, which
      prefers the agent's cached uid over the freshly repointed value and so reverses the
      merge's own `EndpointInventoryMoves` work on the next scan.
- [x] 5.6 `inventory/sync_ingestor.ex`
- [ ] 5.7 `network_discovery/mapper_results_ingestor.ex`
- [ ] 5.8 `inventory/device_source_observation_ingestor.ex` -- **blocked as written**: its test
      is `use ExUnit.Case, async: true` with no `DataCase`
      (`device_source_observation_ingestor_test.exs:2`), so adding a database read to the ingest
      path breaks the database-free unit tier. Either move the pin outside the unit-tested
      function or reclassify the test.

## 6. Reassign what the merge currently misses

- [ ] 6.1 `InterfaceSettings` — identity `[:device_id, :interface_uid]`; not reassigned today,
      which silently stops interface threshold monitoring forever.
- [ ] 6.2 Stateful alert rule state — keyed on an interpolated `"device_id=sr:<uid>"` string
      with no FK. Either reassign it or key it so it can be.
- [ ] 6.3 Ansible/AWX execution targets and holds — RESTRICT FKs that never fire because the
      merge soft-deletes.
- [ ] 6.4 Add each newly reassigned table to the declared reassignment inventory, and add a
      test asserting the inventory matches what the merge actually moves.

## 7. Episodes

The open question that gated this section is **resolved**: the edge never flips (design D7).
`MetricResource.device_id` has zero production writers, so the edge always identifies from a
locally-derived value no merge can change. That inverts the section — continuation is
automatic, and the real defect is elsewhere.

- [x] 7.1 ~~Resolve whether the agent-side `resource.device_id` flips after a merge.~~
      **Answered: it never does, and cannot.** Zero production writers for
      `MetricResource.device_id`; core's own decoder documents this at
      `observability/metric_envelope.ex:58-62`. The edge falls through `anomaly_device_uid` to
      `os.Hostname()` (sysmon), the polled target IP (SNMP) or the agent id (ICMP). No trigger,
      no TTL. Because the edge identity is merge-invariant, `episode_uid` is stable and the
      existing upsert already re-attributes the open episode in place.

- [ ] 7.2 Reassign `anomaly_episodes.device_uid` on merge — **all** episodes on the merged-away
      device, not only open ones. Closed rows never get another report and would otherwise
      reference a tombstoned device forever. Register the column in the task 8.1 inventory so
      the repair fixes history too. Depends on 9.2: without cache invalidation, an in-flight
      report resolving from a stale entry can write the merged-away device back via
      `EXCLUDED.device_uid` for the length of the correlation cache TTL. Note the honest
      scope — for a still-reporting series this write is cosmetic, since the upsert self-heals
      on the next report; its real value is silent and historical episodes.

- [ ] 7.3 **Fix the actual defect.** Add `finding_uid = EXCLUDED.finding_uid` to the
      `ON CONFLICT (episode_uid) DO UPDATE SET` list in `@upsert_sql`
      (`event_writer/processors/anomaly_episode_registry.ex:175-193`) and stop subtracting
      `:finding_uid` in `@episode_upsert_fields` (`observability/anomaly_episode.ex:39`).
      Unconditional, not guarded: `EXCLUDED.finding_uid` is either identical (a normal fold)
      or the newly canonical value (a merge), never a regression.
      Why this matters: core recomputes `finding_uid` from the canonical device, so a merge
      changes it — but the row keeps the pre-merge hash while `device_uid` and `series_key`
      are updated. Both fold arms of the `existing` CTE match on `finding_uid`
      (`anomaly_episode_registry.ex:44-49`), so neither can match that row again. The next
      edge-side episode restart (checkpoint expiry ~6h, or an agent restart) then inserts a
      duplicate and the original is stale-closed as "resolved".

- [ ] 7.4 **Record lineage at ingest, on observation.** When the upsert matches an existing row
      whose `finding_uid` differs from the incoming one, write the previous and new identities
      to `platform.anomaly_finding_lineage` before rewriting, so findings already recorded
      under the old hash stay joinable. Written by ingest when the change is *observed* — never
      by the merge on a prediction about edge behaviour.

- [ ] 7.5 **Pin the continuation that already works.** Regression test: after A is merged into
      B, the next report from the unchanged edge identity lands on the *same* episode row
      (matched by `episode_uid`), with device attribution rewritten to B, `opened_at`
      unchanged, occurrence count incremented, and no second row. This behaviour exists today
      and is untested, which is why nobody knew it was there.

- [ ] 7.6 **Verify before building a merge-specific clear reason.** In this world a merge
      cannot silence a still-reporting producer, so `clear_reason: "stale"` is honest and a
      distinct `identity_merged` state would be a concept operators must learn for a case that
      does not occur. Test instead whether a merge can transiently push an SNMP series onto the
      `{:withhold, ...}` drop path in `resolve_snmp_anomaly_device_uid`, where rows are
      discarded entirely — that is the one plausible merge-caused silence. Build the distinct
      reason only if that test fails.

- [ ] 7.7 Take an explicit position on episode scope: per series, or per series per detector.
      Core collapses the edge's drift and spike finding identities into one recomputed hash, so
      a drift verdict can fold onto a spike episode's open row. Independent of merges, but it
      is decided by the same upsert this section changes.

- [ ] 7.8 Harden or document the incidental dependency. Core's resolution lands on the survivor
      only because the source device is tombstoned **and** its anchors were reassigned;
      `DeviceCorrelation` never calls `follow_canonical_device_id/2` and never reads
      `MergeAudit`. Either route the anomaly path through the merge-aware resolver, or assert
      both preconditions in a test so a future merge variant cannot silently break continuation.

## 8. Repair stranded rows

- [ ] 8.1 Build the declared inventory of device-keyed tables, each marked reassign / leave /
      cannot-reassign. Explicit, not derived by scanning column names.
- [ ] 8.2 Chain resolver: walk `merge_audit` to the terminal canonical device, with a depth
      cap and cycle detection.
- [ ] 8.3 `IdentityStrandedRowRepair` Oban job: keyset-batched, idempotent, resumable,
      with a bounded batch size and an inter-batch pause.
- [ ] 8.4 Dry-run mode producing a per-table candidate report, and no apply path that can run
      by accident.
- [ ] 8.5 **Rate-limit verification**: measure WAL generation for a representative batch size
      before any apply run. This job has the same shape as the bulk rewrite that saturated WAL
      in #3829 — a per-row cost that was invisible until checkpoints ran every ten seconds.
- [ ] 8.6 Review a dry-run report against the demo dataset before running apply anywhere.

## 9. Events and caches

- [ ] 9.1 Give `MergeAudit` a notifier and publish an identity transition naming the previous
      and resulting canonical device ids.
- [ ] 9.2 Invalidate `IdentityCache` and `DeviceCorrelationCache` on that event. Both are
      node-local with no cluster broadcast today, so a merged-away mapping can be served by
      other nodes for the length of the TTL.
- [ ] 9.3 Test that a node not performing the merge stops serving the pre-merge mapping.

## 10. Deferred, with reasons

- [ ] 10.1 `SELECT ... FOR UPDATE` on both device rows inside the merge, which is what turns
      child-table detection into real mutual exclusion. Needs deadlock analysis against
      `ArmisUnmerge`'s existing barrier (`armis_unmerge.ex:719-737`). Gated on step 4
      telemetry showing real collisions.
- [ ] 10.2 Reassigning the full set of device-keyed tables. Larger project, orthogonal to
      fencing, and impossible for hashed identities.
- [ ] 10.3 A merge-stable device lineage id hashed into `finding_uid`. Conclusion unchanged,
      reasoning corrected: the uid scheme does not need changing because the edge identity is
      **already** merge-invariant and core re-keys on ingest.
- [ ] 10.4 Projecting `Agent.device_uid` onto `MetricResource.device_id` so the edge carries a
      canonical, merge-following identity. Independently motivated — the same gap already
      breaks seasonal-baseline delivery for sysmon, since core keys baselines by canonical
      device id while the edge derives `<hostname>|<metric>`, key spaces that cannot match.
      **Blocked on 3.5**, and note it would make `episode_uid` merge-unstable and only then
      create real demand for the successor-uid lineage this proposal removed.
