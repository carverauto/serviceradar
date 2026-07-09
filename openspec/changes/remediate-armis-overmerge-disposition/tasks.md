# Tasks

## 1. Live scoping (decision inputs — run before building the executor)

- [ ] 1.1 Count each population on the target deployment: live Armis-keyed
  devices with ≥2 distinct universal atomic MACs, and devices tombstoned
  `deleted_reason = 'armis_source_device_id_ghost_cleanup'` plus their sole-copy
  `mac` row count. Report the MAC-count distribution. Exclude the demo faker
  fleet (multi-MAC by design is not over-merge) and cross-check a second
  over-merge signal (distinct `integration_id`) before trusting the live-device
  count.
- [ ] 1.2 Decide the `armis_device_id` disposition (survivor-keeps-it vs.
  drop-from-all-split) with the operator/Armis-domain owner.
- [ ] 1.3 Determine whether any co-occurrence provenance survives (mapper/source
  payload history, OCSF device history, interface metadata) to group multi-NIC
  hosts; otherwise confirm per-distinct-MAC over-split is acceptable.

## 2. Shared grouping primitive

- [ ] 2.1 Extract `universal_macs/1` and the disjoint-set predicate from
  `BatchResolver` into a public `ServiceRadar.Inventory.Identity.Mac` helper.
- [ ] 2.2 Point `BatchResolver` at the extracted helper; unit-test parity so the
  veto and the un-merge detector cannot drift.

## 3. Detection + pure decision rules

- [ ] 3.1 Add detection (keyset-paginated, mirroring `blob_purge`) for
  mega-devices and the ghost-tombstoned population; assert `blob-purge` has run
  (zero non-atomic `mac` rows) or normalize in Elixir via `Mac.normalize_mac_list`.
- [ ] 3.2 Add pure `Decisions` functions: group a device's universal MACs into
  target classes, pick the survivor class, mint each target UID via
  `Ids.generate_deterministic_device_id/1`, and classify unsplittable
  (MAC-less / local-only) devices as skipped-with-reason.

## 4. `armis-unmerge` remediation step

- [ ] 4.1 Implement `Remediation.ArmisUnmerge.run(mode, opts, manifest, actor)`
  following `agent_links.ex`: per target group materialize a device
  (adopt-live / `recreate_device` restore-tombstone / create-fresh), move the
  group's `mac` rows via `DeviceIdentifier :reassign_device` (audited, TTL-reset,
  `verified` preserved), place `armis_device_id` per 1.2, and write one
  `merge_audit` `reason: "unmerge"` per split. Dry-run plan vs execute apply.
- [ ] 4.2 `Manifest.record` every device restore/create and identifier reassign
  (ids only), matching the existing rollback format.
- [ ] 4.3 Register the step in `DireRemediation` (`@step_order`, `run_step`
  dispatch) after `agent-links`; ship it dry-run-runnable but excluded from the
  default execute order until 1.x is signed off.

## 5. Tests

- [ ] 5.1 `Decisions` unit tests: universal-MAC grouping, survivor selection,
  deterministic target UID, unsplittable classification (no DB).
- [ ] 5.2 DB test (srql-fixtures scratch): seed a live mega-device (one
  `armis_device_id`, N distinct universal MACs) + a ghost-tombstoned device with
  sole-copy `mac` rows; dry-run asserts the plan; execute asserts per-group
  devices materialized, `mac` rows reassigned + `last_seen` bumped, `unmerge`
  audits written, manifest lines present; re-run is idempotent.
- [ ] 5.3 Regression: after execute, no device has two live devices sharing one
  typed `armis_device_id` (no new `typed_id_on_multiple_devices`); the Armis
  northbound candidate query still loads the survivor.
- [ ] 5.4 Local-only / MAC-less Armis device is reported skipped-with-reason, not
  split.

## 6. Guard removal (separate follow-up change, after live execute verified)

- [ ] 6.1 Verification query: zero sole-copy `mac` rows remain on
  `armis_source_device_id_ghost_cleanup` tombstones.
- [ ] 6.2 Remove the guard in `DeviceIdentifierGcWorker.victim_batch/3` and the
  `DeviceCleanupWorker` retention exclusion; release the ghost tombstones to
  normal retention.
