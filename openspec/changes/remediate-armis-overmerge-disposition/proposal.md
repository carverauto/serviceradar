# Change: Remediate the Armis over-merge — disposition of ghosted mega-devices

## Why

The Armis over-merge is the largest remaining piece of unfinished device-identity
remediation. An Armis "device" (`armis_device_id`) aggregates a whole scanned
subnet, so before the ingest-time distinct-MAC veto existed, `BatchResolver`
resolved every strong-identified update carrying a shared `armis_device_id` to
the **same** canonical device UID at ingest. Distinct hardware (distinct
universally-administered MACs) was written under one UID, producing ~173
"mega-devices" that each carry a whole subnet's worth of MAC identifiers.

Two of the three phases are already done:

- **Prevention (done).** Armis polling `agent_id` values are treated as observer
  provenance rather than endpoint identity, so they cannot bypass
  `BatchResolver.distinct_mac_veto?/3`. The veto returns a new deterministic UID
  when two records' universal-MAC sets are non-empty and disjoint, so new ingest
  never re-collapses distinct hardware.
- **Ghost cleanup + holding pattern (done, live/manual).** A live operation
  tombstoned the affected devices with `deleted_reason =
  'armis_source_device_id_ghost_cleanup'`. The original operation was documented
  as leaving ~389k **sole-copy** `mac` identifier rows on those ghosts. A
  2026-07-09 observation instead found 36,676 protected ghost tombstones owning
  zero `mac` identifier rows, so ~389k remains historical planning context, not
  a current inventory claim. Both maintenance workers were guarded to hold any
  such data stable:
  `DeviceIdentifierGcWorker` never GCs a `mac` row whose parent device carries
  that `deleted_reason` (`device_identifier_gc_worker.ex:170-182`), and
  `DeviceCleanupWorker` never hard-deletes those tombstones
  (`device_cleanup_worker.ex:151`). Both guards are explicitly labelled
  "Remove once disposition completes."

Before this change, the **disposition itself was unbuilt**. Nothing reconstructed
the correct per-hardware devices or reassigned any orphaned `mac` rows found by
live scoping, and the `armis-dups` remediation step went the *wrong* direction
(it collapses onto one canonical) and was disabled by default
(`dire_remediation.ex:19-35`). Because the collapse happened at ingest-resolve
time — not via `merge_devices` — there is
**no `merge_audit` to reverse** (most collapses left no audit row; where rows
exist they never recorded the moved MAC identifiers), so the existing
`IdentityReconciler.unmerge_device/2` cannot be used. This is exactly the reason
`agent_links.ex` reconstructs the worker-chimera split from ground truth instead
of calling `unmerge_device`.

The guards are a holding pattern, not a fix: they protect the tombstone
population but cannot reconstruct hardware identity, and they must stay in place
until disposition verification completes. This change designs and builds that
disposition.

## What Changes

- **New `armis-unmerge` remediation step** in the existing operator-invoked,
  dry-run-default, idempotent, manifest-audited `mix serviceradar.dire_remediation`
  framework. It reconstructs per-hardware target devices from a mega-device's
  distinct universal-MAC groups and moves each group's `mac` identifier rows via
  the audited, TTL-resetting `DeviceIdentifier :reassign_device` action — which
  is simultaneously the "reassign-before-delete" rescue for the sole-copy rows.
  It restores the source ghost when needed but requires every additional
  deterministic target UID to be absent and creates it fresh; any existing
  target or alternate normalized MAC owner is rejected for manual review. A
  per-split `merge_audit` with `reason: "unmerge"` arms the re-collapse cooldown,
  and a synced write-ahead manifest records every candidate and mutation.
- **Extract the veto's MAC grouping primitives** (`universal_macs/1`,
  `distinct_mac_veto?/3` logic) from the private `BatchResolver` into a public
  `Identity.Mac` helper so detection/grouping provably cannot drift from the
  ingest-time veto.
- **Classify the Armis polling agent as observer provenance** so the shared
  poller ID is neither looked up nor registered as endpoint identity before the
  MAC/Armis resolution rules run.
- **Detection + operator dry-run report**: identify mega-devices (an
  Armis-keyed device owning ≥2 distinct universal atomic MACs) and the
  ghost-tombstoned population, with counts, MAC-count distribution, and a
  proposed per-device split plan.
- **Fail-closed execution controls**: keep the step out of the default run,
  allow bounded explicit dry-runs for scoping, and reject execute before any
  mutation until release runtime configuration records operator signoff. Live
  devices require paired device-UID and sync-source-ID allowlists, with
  faker-backed sources always excluded. The CLI prints explicitly selected
  reports and exits unsuccessfully on any nonzero execute failure count.
- **Keep the two GC guards in place** while this dormant executor is shipped.
  Remove them only in a separately reviewed follow-up after live execution and a
  verification query prove that no sole-copy MAC rows remain on the protected
  tombstones.
- **Explicit non-goals** persisted in the spec: MAC-less and local-MAC-only
  Armis collapses are not splittable by MAC and stay out of scope; the step
  never uses `armis_device_id` alone or `source_device_id` as a merge/split key.

## Impact

- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `ServiceRadar.Inventory.Remediation.DireRemediation` (`@step_order`,
    `default_steps`, `run_step` dispatch), `Remediation.Decisions` (pure
    grouping/target rules), new `Remediation.ArmisUnmerge` step
  - `ServiceRadar.Inventory.Identity.BatchResolver` /
    `ServiceRadar.Inventory.Identity.Mac` (extract `universal_macs` to public)
  - `ServiceRadar.Inventory.DeviceIdentifierGcWorker` and
    `ServiceRadar.Inventory.DeviceCleanupWorker` remain unchanged until the
    separately gated guard-removal follow-up
- Affected data: `platform.ocsf_devices` (reconstruct/restore per-hardware
  devices while protected ghost tombstones remain guarded),
  `platform.device_identifiers` (reassign any scoped sole-copy `mac` rows —
  audited, TTL-reset; the 2026-07-09 observation found zero on 36,676 protected
  ghosts), `platform.merge_audit`
  (one `unmerge` row per split)
- Depends on: `blob-purge` (step 1) having run so blob-hidden MACs are atomic
  before detection. Complements the completed
  `refactor-device-identity-reconciliation`.
