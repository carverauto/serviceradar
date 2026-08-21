# Tasks

## 0. Prerequisite

- [ ] 0.1 Land #3831 — `MergeEngine` must use `Ash.transact/3` so a failed merge rolls back.
      A state-derived fence is unsound while a half-merged device can exist.

## 1. Schema

- [ ] 1.1 Migration: `ALTER TABLE platform.ocsf_devices ADD COLUMN identity_revision bigint
      NOT NULL DEFAULT 1`. Catalog-only on modern PostgreSQL; no backfill. Do **not** name it
      `identity_version` — that is the virtualization-v3 identity schema version.
- [ ] 1.2 Same migration: `merge_audit` indexes `(from_device_id, created_at)` and
      `(to_device_id)`, `concurrently: true` with `@disable_ddl_transaction true` and
      `@disable_migration_lock true`. The table has had only its primary key since creation.
- [ ] 1.3 Migration: `platform.anomaly_finding_lineage` — previous finding uid, successor
      finding uid, episode uid, device uids, created_at; unique on the previous finding uid.
- [ ] 1.4 Expose `identity_revision` on the `Device` Ash resource as a read-only attribute.

## 2. The bump

- [ ] 2.1 `Device :bump_identity_revision` with an `atomic/3` callback returning
      `{:atomic, %{identity_revision: expr(^atomic_ref(:identity_revision) + 1)}}`.
      Never `require_atomic? false`.
- [ ] 2.2 Unit tests: monotonic, atomic under concurrency, not bumped by `:touch`,
      `:gateway_sync` or `:set_availability`.
- [ ] 2.3 Call it from every identity transition. All eight, not just the merge:
  - [ ] 2.3.1 `merge_engine.ex` `do_merge_devices` — source **and** survivor. The survivor
        bump is a new write; `:229` only reads B today.
  - [ ] 2.3.2 `merge_engine.ex` `do_unmerge` — both devices.
  - [ ] 2.3.3 `alias_guard.ex` `invalidate_ip_alias`
  - [ ] 2.3.4 `remediation/agent_links.ex`
  - [ ] 2.3.5 `remediation/armis_unmerge.ex` (the split path)
  - [ ] 2.3.6 `identity/registrar.ex` (both transition points)
  - [ ] 2.3.7 `identity/reassignments.ex` — `DeviceIdentifier :reassign_device`
  - [ ] 2.3.8 `device.ex` `:soft_delete` and `:restore`
- [ ] 2.4 Integration test per transition type asserting the bump, including that an unmerge
      increments rather than restoring the previous value.

## 3. Pin and check

- [ ] 3.1 Add `resolve_device_identity/2` returning `{uid, identity_revision}`. Do **not**
      change `resolve_device_id/2`'s return type — roughly ten callers plus an Ash action.
- [ ] 3.2 Compare-and-set helper using `Ash.Changeset.filter(expr(identity_revision == ^pinned))`
      on the pending caller changeset, handling `Ash.Error.Changes.StaleRecord` as a value.
- [ ] 3.3 Staleness policy helper: re-resolve once, retry once, then abandon and emit
      telemetry. Never raise; never drop silently. Abandon after two observed transitions.
- [ ] 3.4 Telemetry events under `[:serviceradar, :identity_fence, ...]` carrying pipeline,
      device id, pinned revision and observed revision.
- [ ] 3.5 **Fix the re-resolution no-op**: `DeviceCorrelation.explicit_device_uid`
      (`device_correlation.ex:219-233`) short-circuits on `"sr:" <> _` and returns the uid
      with no existence check, so it re-resolves nothing in production. Either make it check,
      or delete it and route callers through the pinned resolver — do not leave a helper whose
      name promises a guarantee it does not provide.

## 4. Observe-only rollout

- [ ] 4.1 Pin `edge/agent_gateway_sync.ex:285-320` — resolves identity once, then six
      independent writes. The clearest case.
- [ ] 4.2 Pin `composite_checks/refresh_worker.ex` — an Oban job whose only argument is a
      device uid. The pinned revision goes in job args under a string key (Oban args are
      string-keyed).
- [ ] 4.3 Ship both comparing and reporting only. Enforce nothing.
- [ ] 4.4 Run for a measured period and read the telemetry. Treat demo identity signals with
      care — `armis_unmerge.ex:42-49` records that faker data makes some unreliable.
- [ ] 4.5 Decide enforcement per pipeline from what the telemetry actually shows.

## 5. Extend pinning

Target roughly ten pinned paths total; below that the fence is decoration.

- [ ] 5.1 `sweep_jobs/sweep_results_ingestor.ex`
- [ ] 5.2 `event_writer/processors/sweep.ex`
- [ ] 5.3 `event_writer/processors/metrics.ex`
- [ ] 5.4 `core/result_processor.ex`
- [ ] 5.5 `inventory/endpoint_inventory_ingestor.ex` — also fix `build_context/5`, which
      prefers the agent's cached uid over the freshly repointed value and so reverses the
      merge's own `EndpointInventoryMoves` work on the next scan.
- [ ] 5.6 `inventory/sync_ingestor.ex`
- [ ] 5.7 `inventory/mapper_results_ingestor.ex`
- [ ] 5.8 `inventory/device_source_observation_ingestor.ex`

## 6. Reassign what the merge currently misses

- [ ] 6.1 `InterfaceSettings` — identity `[:device_id, :interface_uid]`; not reassigned today,
      which silently stops interface threshold monitoring forever.
- [ ] 6.2 Stateful alert rule state — keyed on an interpolated `"device_id=sr:<uid>"` string
      with no FK. Either reassign it or key it so it can be.
- [ ] 6.3 Ansible/AWX execution targets and holds — RESTRICT FKs that never fire because the
      merge soft-deletes.
- [ ] 6.4 Add each newly reassigned table to the declared reassignment inventory, and add a
      test asserting the inventory matches what the merge actually moves.

## 7. Episode lineage

- [ ] 7.1 **Resolve the open question first**: does the agent-side `resource.device_id`
      flip to the survivor after a merge, and how quickly? This was inferred, not proven.
      It determines whether continuation is the common path or the rare one.
- [ ] 7.2 Reassign `anomaly_episodes.device_uid` on merge so device-scoped reads follow.
      The hashed `episode_uid` stays as an opaque surrogate key.
- [ ] 7.3 Write lineage rows on merge for each open episode, computing the successor
      `finding_uid` by substituting the canonical device uid into the known template.
- [ ] 7.4 Ingest: when a report arrives under a successor identity with open lineage,
      continue the existing episode instead of opening a new one. Do not reset the baseline.
- [ ] 7.5 `AnomalyEpisodeStaleCloseWorker`: close merge-orphaned episodes with a clear reason
      identifying an identity merge, distinct from the reason used for a producer that
      stopped reporting.
- [ ] 7.6 Tests for all four scenarios in the anomaly-detection delta.

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
- [ ] 10.3 A merge-stable device lineage id hashed into `finding_uid` instead of the device
      uid. The "correct" fix for episodes, but a breaking change to an edge-computed identity
      with an agent rollout, for a problem step 7 solves at core with no ABI change.
