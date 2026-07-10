# Tasks

## 1. Live scoping (decision inputs — run before building the executor)

- [ ] 1.1 Count each population on the target deployment: live Armis-keyed
  devices with ≥2 distinct universal atomic MACs, and devices tombstoned
  `deleted_reason = 'armis_source_device_id_ghost_cleanup'` plus their sole-copy
  `mac` row count. Report the MAC-count distribution. Exclude the demo faker
  fleet (multi-MAC by design is not over-merge) and cross-check a second
  over-merge signal (distinct `integration_id`) before trusting the live-device
  count.
  - 2026-07-09 observation (not signoff): 36,676 ghost-cleanup tombstones owned
    zero MAC identifier rows. The 14,862 live candidates all resolved to one
    sync source whose endpoint is `http://serviceradar-faker:8080`; 14,860 had
    `FAKER-*` hostnames and the other two were also sourced by that faker
    integration. A MAC-count distribution and non-faker target population still
    need to be established, so this task remains open.
- [x] 1.2 Approve and implement the `armis_device_id` disposition: the retained
  survivor keeps the sole typed Armis identifier and reconstructed split
  devices remain MAC-only. Tests assert a single typed owner and continued
  northbound resolution through the survivor.
- [ ] 1.3 Determine whether any co-occurrence provenance survives (mapper/source
  payload history, OCSF device history, interface metadata) to group multi-NIC
  hosts; otherwise confirm per-distinct-MAC over-split is acceptable.

## 2. Shared grouping primitive

- [x] 2.1 Extract `universal_macs/1` and the disjoint-set predicate from
  `BatchResolver` into a public `ServiceRadar.Inventory.Identity.Mac` helper.
- [x] 2.2 Point `BatchResolver` at the extracted helper; unit-test parity so the
  veto and the un-merge detector cannot drift.
- [x] 2.3 Treat the first-party Armis runtime's shared polling `agent_id` as
  observer provenance so it is neither looked up nor registered as discovered
  endpoint identity ahead of the distinct-MAC veto.

## 3. Detection + pure decision rules

- [x] 3.1 Add detection (bounded per-run `armis_unmerge_candidate_limit`, default
  5,000 for dry-run and 25 for execute; idempotent re-runs converge on the
  remainder because a split device drops out of candidacy) for mega-devices and
  the ghost-tombstoned population; assert `blob-purge` has run (zero non-atomic
  `mac` rows) or normalize in Elixir via `Mac.normalize_mac_list`.
- [x] 3.2 Add pure `Decisions` functions: group a device's universal MACs into
  target classes, retain the survivor UID, mint each additional stable
  remediation UID from `{armis_id, MAC, partition}`, and classify unsplittable
  (MAC-less / local-only / missing-partition / mixed-partition) devices as
  skipped-with-reason. Require one canonical nonblank partition on every
  universal MAC row and never synthesize `default`. UID parity is asserted only
  for canonical Armis-only updates; convergence for enriched shapes relies on
  reassigned typed MAC ownership. Reject display blobs matching multiple planned
  classes as `ambiguous_display_mac`. Live candidates additionally require a
  canonical integration-source partition equal to the universal-MAC partition.

## 4. `armis-unmerge` remediation step

- [x] 4.1 Implement `Remediation.ArmisUnmerge.run(mode, opts, manifest, actor)`
  following the `agent_links.ex` transaction pattern: retain/restore only the
  source survivor, require additional deterministic targets to be absent and
  create them fresh, move each group's `mac` rows via `DeviceIdentifier
  :reassign_device` (audited, TTL-reset, `verified` preserved), place
  `armis_device_id` per 1.2, and write one
  `merge_audit` `reason: "unmerge"` per split. Dry-run plan vs execute apply.
- [x] 4.2 Sync a write-ahead candidate preflight before mutation, batch-append
  exact prepared restore/create/reassign/audit entries with one sync per
  candidate before database commit, and sync a committed marker afterward;
  propagate every manifest failure and create manifests exclusively so rollback
  evidence is never overwritten.
- [x] 4.3 Register the step in `DireRemediation` (`@step_order`, `run_step`
  dispatch) after `agent-links`; ship it explicit dry-run-runnable, excluded from
  the default order, and reject execute before any mutation unless a runtime
  signoff gate is enabled. Live-device execution additionally requires paired,
  nonempty device-UID and sync-source-ID allowlists and rejects faker-backed
  sources. Require typed Arm and independent integration-ID evidence metadata to
  match that canonical Armis source.
- [x] 4.4 Expose validated candidate/plan-sample bounds and paired live
  allowlists in the Mix task, print reports for explicitly selected dormant
  steps, and return a failing command status after printing any nonzero execute
  failure counts. Keep dry-run discovery at 5,000 by default but bound execute
  to 25 candidates, indexed normalized-owner lookups, and fail-closed owner-table
  lock/statement timeouts. Convert database timeout exceptions into inspectable
  per-candidate failures without bypassing the report or manifest path.

## 5. Tests

- [x] 5.1 `Decisions` unit tests: universal-MAC grouping, survivor selection,
  deterministic target UID, and missing/blank/mixed partition unsplittable
  classification plus multi-class display ambiguity (no DB).
- [x] 5.2 DB test (srql-fixtures scratch): seed a live mega-device (one
  `armis_device_id`, N distinct universal MACs) + a ghost-tombstoned device with
  sole-copy `mac` rows; dry-run asserts the plan; execute asserts per-group
  devices materialized, `mac` rows reassigned + `last_seen` bumped, `unmerge`
  audits written, manifest lines present; re-run is idempotent.
- [x] 5.2a DB regressions: missing/blank/mixed partitions and multi-class display
  MACs are reported without mutation; integration-source partition mismatch and
  post-plan drift fail closed; forced owner-barrier lock timeout returns a
  structured nonzero report with its manifest path.
- [x] 5.3 Regression: after execute, no device has two live devices sharing one
  typed `armis_device_id` (no new `typed_id_on_multiple_devices`); the Armis
  northbound candidate query still loads the survivor.
- [x] 5.4 Local-only / MAC-less Armis device is reported skipped-with-reason, not
  split.
- [x] 5.5 Add pure orchestrator and Mix-task tests for the execute gate,
  candidate/sample bounds, paired live allowlists, explicit-step reporting, and
  nonzero failure propagation.
- [x] 5.6 Add production-shaped SyncIngestor regressions proving that a shared
  Armis polling agent cannot bypass the distinct-MAC veto, register a poller
  identifier on discovered endpoints, or resolve an endpoint onto the poller's
  own host.

## 6. Guard removal (separate follow-up change, after live execute verified)

- [ ] 6.1 Verification query: zero sole-copy `mac` rows remain on
  `armis_source_device_id_ghost_cleanup` tombstones.
- [ ] 6.2 Remove the guard in `DeviceIdentifierGcWorker.victim_batch/3` and the
  `DeviceCleanupWorker` retention exclusion; release the ghost tombstones to
  normal retention.
