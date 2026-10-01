# Change: Retire source ids a source stops reporting, and converge their records

## Why

An authoritative inventory source can re-identify an asset. It starts reporting the asset under
a new source id (for example a new Armis device id) and stops reporting the old one. The MAC
stays the same, and usually so do the hostname and the source's own first-seen time.

DIRE handles the new id by design. Under the source-authority guard (`SourceAuthorityGuard`), a
record holding a different source id of the same type is never a match, so the new id gets a new
record. Nothing handles the old id:

- No lifecycle event exists for "the source stopped reporting this id". The old record keeps
  the id for ever, so the guard keeps treating it as a live rival of the new record.
- The network sweep keeps refreshing the old record's last-seen time, so it never looks stale.
  Ephemeral expiry skips it, because it holds a strong identifier.
- The address-claim rule compares the incoming source sighting with that sweep-refreshed
  last-seen time, so the old record often keeps the address as well.
- The scheduled duplicate sweep finds the pair through the shared MAC on every run. The merge
  is refused as a source-authority conflict and counted as an error, every five minutes, for
  every pair.

Inventory therefore grows by one record per re-identified asset, and every one of those records
looks live.

Separately, when an identified device takes the only address of an anchorless sweep seed, the
spec says the seed "SHALL release address A and stay live". The released seed has no address
and no identifiers. Only ephemeral expiry, which is off by default, ever removes it, so released
seeds accumulate. Enabling expiry does not fix this: a released shell is never seen again, so
it lives exactly one expiry window, and the pile settles at the window times the release rate.

Reviewing ephemeral expiry against this showed three more defects:

- **A sweep never restores an expired sweep-only device.** `restore_eligible?/1` in the sweep
  ingestor restores only devices with a non-sweep discovery source, the sweep's address lookup
  falls back to the tombstone, and the availability update has no `deleted_at IS NULL`
  predicate. A returning sweep-only host refreshes an invisible tombstone until the purge. The
  expiry module documentation and the settings page both promise the opposite.
- **A source id kept only in metadata is held from expiry by an in-memory check alone.**
  `platform.device_holds_strong_identifier/1`, which the delete statement re-checks, reads only
  the identifier tables.
- **The expiry guard and logs count the wrong things under their names.** The guard judges every
  stage-1 candidate, before the keep checks, and the result's `excluded` counts the devices the
  keep checks kept, not matches of the exclusion query.

A stable source id with a changing address already resolves correctly. The defect is specific
to a source id that changes.

The DIRE formal model did not catch this. It passes in CI, but:

- it models each device's source id as a constant, so no behavior can re-key a device;
- no invariant asks for one record per source asset (`DistinctSourceIdsNeverMerge` forbids the
  opposite direction, and `EvidenceConverges` exempts source conflicts);
- it has no source collections, no absence and no retirement.

Two committed regression traces record the behavior above as correct:

- `src_attach_shared_mac` records the split, with nothing to follow it once an id is absent.
- `armis_moves_onto_sweep_seed` records the seed that "releases it and stays live".

The fix contradicts the current spec. "Source-Authoritative Identifiers Govern Identity" says
two records holding different values "SHALL NOT be merged, whatever MAC or address evidence
they share", and it has no notion of a value the source no longer reports. The provisional-seed
scenario of "Address Is Evidence, Not Identity" specifies the leak.

## What Changes

- **Current and retired source ids.** A source-authoritative id is *current* while its source
  keeps reporting it.
  - It is *retired* once it has been absent from N consecutive exact, activated collections of
    its source (default 3) and has not been reported for at least T (default 24 hours).
  - Retiring moves the identifier row to `platform.device_identifier_archive` with its
    provenance and records a `source_id_retired` identity decision.
  - Only exact, activated collections count. A source without them (NetBox today) never
    retires an id.
  - N and T are operator settings. The classifier generalizes
    `Remediation.ArmisSourceIdentityRepair` to every source-authoritative type.
- **A retired id keeps one veto and loses one.**
  - Ingest does not change. A record that holds or held a different source id of the same type
    is still never a match, so a MAC can never attach a new source id to an old record.
  - A retired id stops blocking the reconciler's corroborated succession, and nothing else. A
    current id still blocks every automatic merge.
- **Corroborated succession, in the reconciler only.** `DuplicateSweep` converges a record
  holding only retired ids of a type with the record holding the current id of that type when
  all of these hold:
  - they share a universally administered, non-multicast MAC that links the retired record to
    no other current record;
  - they have an equal source first-seen time or an equal hostname;
  - the pairing is one-to-one.

  The older record survives and takes the current id. The merge uses reason
  `source_succession`, goes through `MergeEngine` with its guards, writes `merge_audit` with the
  evidence, and can be unmerged.
- **Review, not merge, where evidence is weaker.** A shared MAC alone is never sufficient,
  because cloned virtual machines share MACs. These cases go to the de-duplication review queue
  instead:
  - an equal hostname and first-seen time without a shared MAC;
  - a shared MAC with neither corroborating field;
  - any pairing that is not one-to-one.
- **Retired records with no successor.** A record left holding only retired source ids is
  marked `source_retired` straight away. It is hidden from default inventory reads and counts,
  visible with a filter, and still a succession candidate.
  - After a grace period (default 7 days) it is soft-deleted with
    `deleted_reason = "source_retired"` and releases its address.
  - A sweep, address-only or MAC-only sighting never restores it.
- **A retired id presented again** returns to its archived holder only with the same
  corroboration. Otherwise it gets a new record and a `source_id_reissued` decision, which
  opens a review task. The archive never merges two live records.
- **Address claims.** A record whose source ids are all retired never keeps an address against
  a record holding a current id. Between two identified records, the newer-observation rule
  compares their last identity-bearing observations, which sweeps and address-only sightings
  never advance.
- **Released seeds retire.** An anchorless sweep seed that releases its only address to an
  identified device is soft-deleted in the same transaction, with
  `deleted_reason = "seed_released"`. This, not ephemeral expiry, is the fix for the shell
  pile-up: it is the only rule under which no addressless shell is ever live. Expiry only bounds
  the pile, and the existing pile is the remediation's job.
- **Expired sweep-only devices come back.** A sweep restores a `stale_ephemeral` tombstone it
  matches, through the audited restore path, whatever the device's discovery sources. No sweep
  write lands on a tombstone it does not restore. The expiry module documentation and the
  settings-page text are corrected to match.
- **Expiry hold and counters.**
  - The SQL strong-identifier hold also covers an agent id or source id recorded only in device
    metadata, so the delete statement holds those devices itself.
  - The expiry guard judges the devices a pass would actually expire.
  - The result, logs and telemetry report `candidates`, `kept_by_evidence`,
    `kept_by_exclusion`, `eligible`, `expired` and `skipped_at_delete`.
- **Blocked components are not retried.** The scheduled sweep skips a blocked component whose
  evidence fingerprint is unchanged since it was last blocked. The fingerprint covers the
  device set, the live and archived identifiers, the assertions and the rule version. The run
  record reports blocked components apart from errors.
- **Guardrails.**
  - A mass-retirement guard refuses, and records, any retirement or grace-delete pass that
    would affect more than a configured fraction of a source instance's live records.
  - Telemetry for the live-to-current ratio per source, the records holding only retired ids,
    the `source_retired` records, the released-seed shells and the reconciler's
    blocked-component counts.
  - `MergeDeviceFacts` reserves the identity-bearing metadata keys.
- **Formal model.**
  - The source id becomes a variable with a re-key action.
  - The model gains source collections, absence, retirement and reconciler succession, with a
    coarse freshness clock.
  - New properties:
    - `OneSourceRecordPerDevice`, at rest;
    - `CurrentSourceIdResolves`;
    - `SuccessionIsCorroborated`;
    - `NoMergeOfCurrentSourceIds`;
    - `NoAddresslessShell`.
  - Today's behavior becomes defect switches with witnesses.
  - The rejected alternatives (MAC-only succession, forgetting retired ids) become negative
    configurations that must violate `NoFalseMerge`.
  - The two traces are corrected.
  - The lifecycle model stops assuming that ephemeral expiry runs, and models which tombstones a
    sweep restores by the device's discovery sources.
- **Remediation.** Dry-run-first, batched, reversible steps in `mix serviceradar.dire_remediation`
  (`source-id-retire`, `source-succession`, `released-seed-shells`), with:
  - per-class dry-run counts;
  - an NDJSON manifest and `merge_audit`;
  - rollback by unmerge, unarchive, clearing the retired mark and restore;
  - verification checks between batches.

  No pre-run backup is required. Rollback works per action from the manifest. The steps run
  only after the fix ships.

## Impact

- Affected specs:
  - `device-identity-reconciliation`
  - `device-inventory`
  - `dire-formal-model`
- Affected code, under `elixir/serviceradar_core/lib/serviceradar/inventory/`:
  - `identity/source_authority_guard.ex`
  - `identity/duplicate_sweep.ex`
  - `identity/merge_engine.ex`
  - `sync/device_writes.ex`
  - `armis_source_snapshot.ex`
  - `changes/merge_device_facts.ex`
  - `identity_decision.ex`
  - `ephemeral_device_expiry.ex`, for the guard, the counters and the module documentation
  - `device_cleanup_worker.ex`, for the grace delete and the expiry log line
  - `remediation/armis_source_identity_repair.ex`
  - `remediation/dire_remediation.ex`
  - the device read actions
- Affected elsewhere in `serviceradar_core`:
  - `sweep_jobs/sweep_results_ingestor.ex`, for the restore rule and the tombstone predicate
  - `identity/device_lookup.ex`, read-only: its tombstone fallback stays
- Affected outside it:
  - `rust/srql/src/query/devices.rs`, the default device filter
  - `formal/dire/**`
  - the DIRE trace tests
  - web-ng inventory filters and the Inventory Cleanup settings page, including its restore text
- Data:
  - Schema additions only: a retired-at column and an identity-observed-at column on
    `ocsf_devices`, an archive lookup index, settings fields, and a redefined
    `platform.device_holds_strong_identifier/1`.
  - No migration backfills data. The existing backlog is the remediation's job.
- **BREAKING (behavior):**
  - Default inventory reads and counts stop including `source_retired` records.
  - The reconciler's error count stops including blocked merges.
  - A sweep restores expired sweep-only devices.
  - The expiry result map renames `excluded`; dashboards and alerts that read it must move to
    the new counters.
- Related changes:
  - `refactor-device-identity-reconciliation`:
    - its pending identifier TTL garbage collection and cardinality cap must not remove a
      source-authoritative id, which leaves the live table only by retirement, merge or
      unmerge;
    - its remediation framework is reused.
  - `add-device-delete-guardrails`: it carries a pending copy of "Restore Soft-Deleted
    Devices", which must be reconciled with this change's version.
  - `add-estate-decommissioning-controls`: it ages devices by last-seen, which a sweep keeps
    fresh. This change ages source records by source absence instead.
  - `add-ephemeral-device-expiry`: expiry never reaches a record holding a strong identifier,
    so it cannot clean up the duplicates. This change corrects its sweep restore, its SQL hold
    and its counters. Its pending "Ephemeral Device Expiry" requirement is left as written; the
    new requirements here sit beside it.
  - `add-canonical-device-facts-and-source-disagreement`: its fact provenance drives the
    succession fact merge.
  - `add-hermetic-armis-dire-e2e`: its harness gains the re-key scenarios.
  - `add-agent-self-report-device-identity`: agent-id rotation stays out of scope here.
