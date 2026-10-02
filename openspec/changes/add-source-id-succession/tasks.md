# Tasks

Every fixture, trace and example in these tasks is synthetic: invented uids, Armis and NetBox
ids such as 1001 and 2002, `00:00:5e:00:53:xx` MACs, `192.0.2.0/24` and `198.51.100.0/24`
addresses and `example.com` hostnames. Load the `test-audit` skill before writing or changing
any test.

## Delivery order (D15)

Eight pull requests, each green and safe on its own:

| PR | Decisions | Tasks |
| --- | --- | --- |
| 1 | D10 | 1 |
| 2 | D1, D2 | 2, 3, 4 (4.2's `source_succession` exception goes with PR 5) |
| 3 | D5, D6 | 6, 7 |
| 4 | D7, D8 | 8 |
| 5 | D3, D4 | 5 |
| 6 | D9 | 10, 11 |
| 7 | D12, D13, D14 | 9 |
| 8 | D11 | 13, 14.11 |

Each fix pull request carries its part of 12.1 and its tests: 14.1 and 14.2 go with PR 2
(14.2's corroborated succession with PR 5), 14.4 and 14.5 with PR 3, 14.6 with PR 4, 14.3 with
PR 5, 14.9 with PR 6, 14.7 and 14.8 with PR 7, and 14.10 with PR 8. 14.12 and 14.13 apply to
every pull request, and 2.4 to every one that adds a migration.

## 1. Formal model first (D10)

This section lands as its own pull request, before any code. If TLC finds a counterexample to a
goal property in 1.1-1.6, stop and revise `design.md` before writing code.

- [x] 1.1 `DireResolution.tla`: make the source id a variable (`srcOf`, initialized from
      `SrcOf0`); add `Rekey(h, a)` gated by a `Rekeys` constant, and `FreshIds`; add the
      `recFs` ghost for first-seen and hostname corroboration, the `HostOf` constant so devices
      can share a hostname, the `NewFirstSeenIds` constant so a re-key can change a device's
      first-seen time, and the `seenWith` ghost for D3's time guard.
- [x] 1.2 Add `Collect`, the `Fresh | Stale` absence clock and `RetireAbsent(a)`; make ingest
      consult the archive; add the reconciler's `Succeed` and `Review` with D3's succession and
      D4's review decisions; add `addrFresh`, a per-record flag that a sighting which is not
      identity-bearing touched the record last, standing for the identity-observation
      freshness the sweep never refreshes.
- [x] 1.3 Add the properties `OneSourceRecordPerDevice` (at rest), `CurrentSourceIdResolves`,
      `SuccessionIsCorroborated`, `NoMergeOfCurrentSourceIds` and `NoAddresslessShell`, and the
      `NeverSucceeds` helper for the vacuity check.
- [x] 1.4 Add the environments `armis_rekey`, `armis_rekey_shared_mac`, `armis_reissued_ids`,
      `armis_clones` and `armis_rekey_new_first_seen` to `MCDireResolution.tla`, a
      `resolution_goal_*` configuration for each, and `resolution_vacuity_succession` and
      `resolution_vacuity_hostname_succession` (each expects `violation:NeverSucceeds`). Every
      existing goal configuration still passes unchanged. `armis_reissued_ids` is split, with
      `armis_reissued_ids_one_device`, to stay inside the runtime budget.
- [x] 1.5 Add the `Unsafe` constant with `ASSUME Unsafe \subseteq UnsafeAlternatives`, and the
      negative configurations `resolution_unsafe_mac_only_succession` (environment
      `armis_rekey_shared_mac`), `resolution_unsafe_retired_ids_forgotten` (environment
      `armis_reissued_ids`) and `resolution_unsafe_overlapping_hostname_corroborates`
      (environment `armis_clones`), each expecting `violation:NoFalseMerge`. No goal or trace
      configuration sets `Unsafe`.
- [x] 1.6 Confirm each of today's defects against the Elixir code, then add the switches
      `retired_source_id_vetoes`, `stale_holder_keeps_address` and `released_seed_stays_live` to
      `KnownBugs` and `CurrentBugs.ResolutionBugs`, with witnesses expecting
      `violation:OneSourceRecordPerDevice`, `violation:ObservedAddressHeld` and
      `violation:NoAddresslessShell`.
- [x] 1.7 `DireLifecycle.tla`: gate `Expire` by `ExpiryEnabled`; add the reasons `expired`,
      `source_retired` and `seed_released`; add `Retire` (which is also `MarkRetired`) and
      `GraceDelete`, gated by `RetirementEnabled`, an evidence sighting of a `source_retired`
      tombstone, and reactivation; add `RetiredTombstoneStaysDeleted` and
      `MarkedHoldsNoIdentifier`; add `lifecycle_goal_no_expiry`, `lifecycle_goal_retirement`,
      `lifecycle_goal_retirement_chain`, `lifecycle_vacuity_grace_delete` (expects
      `violation:NeverGraceDeletes`) and `lifecycle_vacuity_reactivate` (expects
      `violation:NeverReactivatesRetired`).
- [x] 1.8 `DireLifecycle.tla`: add a per-record sweep-only discovery flag and `SweepCreate`;
      make `Sweep(p, d)` match the live holder or a tombstone and restore it (`SweepRestore`)
      by `SweepResultsIngestor.restore_eligible?/1`; add `SweepRefresh` and `SweepSkip`; add
      `SweepWritesOnlyLiveRecords`, `ExpiredDeviceReturns` and
      `lifecycle_vacuity_expired_returns` (expects `violation:NeverRestoresExpired`); confirm the
      defect against the code and add the switch `sweep_refreshes_expired_tombstone` to
      `KnownBugs` and `CurrentBugs.LifecycleBugs`, with a witness expecting
      `violation:ExpiredDeviceReturns`.
- [ ] 1.9 Traces in `dire_resolution_trace_test.exs`: extend `src_attach_shared_mac` so the
      first device leaves Armis for N exact collections; add `src_rekey_succession`; keep
      `armis_moves_onto_sweep_seed`. Record each from today's code with
      `DIRE_TRACE_WRITE=1`. `armis_moves_onto_sweep_seed` demonstrates
      `released_seed_stays_live` with a knockout configuration
      (`assert_golden!(demonstrates: ...)`). `retired_source_id_vetoes` only withholds
      retirement, so with it knocked out the model allows more, never less, and no knockout can
      reject a trace. `src_rekey_succession` demonstrates it with a trace witness configuration
      instead (`assert_golden!(witness: ...)`, expects `violation:OneSourceRecordPerDevice`).
      The extended `src_attach_shared_mac` violates nothing today and is the fix's regression
      trace.
- [x] 1.10 Trace in `dire_lifecycle_trace_test.exs`: add `expired_sweep_only_returns`, with its
      knockout for `sweep_refreshes_expired_tombstone`. `sweep_restores_merged` now records the
      sweep's write to the merged tombstone (`SweepRefresh`) and gets a knockout for the same
      switch.
- [ ] 1.11 Wire every new configuration and trace into `formal/dire/BUILD.bazel` as
      `tlc_test` targets selected by `make test`, with `expect = "pass"`,
      `"violation:<Prop>"` as above. Bump the selected-test counts in
      `build/integration_test_dispositions.bzl` for each new trace test, and keep each check
      inside its runtime budget by splitting the environment, never by excluding it.
- [ ] 1.12 Update `formal/dire/README.md`: the scope, the new switches and alternatives, and
      "What the models do not express" (the absence clock is coarse; telemetry re-keying and
      agent-id rotation are not modeled).

## 2. Schema and settings (D1, D5, D6, D7)

- [ ] 2.1 Migration: add `source_retired_at` and `identity_observed_at` to `ocsf_devices`, with
      an index serving the default-read filter and the grace query; add an index on
      `device_identifier_archive (identifier_type, identifier_value, partition)`. The
      migration changes schema only and backfills nothing.
- [ ] 2.2 Add to `DeviceCleanupSettings` (database-backed, never application env):
      `source_retirement_enabled` (default true), `source_retirement_absent_collections`
      (default 3), `source_retirement_min_absence` (default 24 hours),
      `source_retirement_max_fraction` (default 0.5), a one-pass
      `source_retirement_guard_override`, `source_retired_grace` (default 7 days) and
      `max_successions_per_run` (default 200). Seed the defaults in the settings seeder.
- [ ] 2.3 Add the new fields to the Inventory Cleanup settings page in web-ng.
- [ ] 2.4 Bump `core.migrations.expectedVersion` in `helm/serviceradar/values.yaml` to the
      newest migration this change adds, in the same pull request as each migration.

## 3. Retirement (D1)

- [ ] 3.1 Generalize `Remediation.ArmisSourceIdentityRepair` into a source-neutral classifier
      that reads the type map from `SourceAuthorityGuard` and applies the N, T and query-hash
      rules against exact, activated collections. Keep its dry-run output.
- [ ] 3.2 Enqueue a retirement job when an exact collection activates
      (`ArmisSourceSnapshot.activate/3`); never retire during ingest; fail closed for a type
      with no exact collections or a scope that maps to more than one source instance.
- [ ] 3.3 Retire in one transaction: move the identifier row to the archive with
      `archive_reason = "source_absent"`, and record a `source_id_retired` identity decision with
      the proving collection ids.
- [ ] 3.4 Mass guard: refuse a pass over the fraction, log at error level with the counts, emit
      telemetry, and clear the override after the pass it admits.
- [ ] 3.5 Coordinate with `refactor-device-identity-reconciliation`: its identifier TTL garbage
      collection and cardinality cap exempt source-authoritative types.

## 4. Veto split (D2)

- [ ] 4.1 `SourceAuthorityGuard` consults the archive as well as `device_identifiers`: a record
      that holds or held a different value of the type is never an ingest match.
- [ ] 4.2 `MergeEngine`: every automatic reason keeps refusing a retired rival; only
      `source_succession` passes when D3 holds; `manual*` and `unmerge` are unchanged.
- [ ] 4.3 Add the new decision kinds `:source_id_retired`, `:source_id_reactivated`,
      `:source_id_reissued` and `:succession_review` to `IdentityDecision`; the last two open a
      de-duplication task.

## 5. Succession and review (D3, D4)

- [ ] 5.1 In `DuplicateSweep`, after the blocked components are known, find predecessor and
      successor pairs and apply D3's conditions: a shared universal, non-zero, non-broadcast
      MAC linking the predecessor to no other current record; agreement on first-seen time, or
      on a hostname no other current record of the source holds when the successor's first-seen
      time is no earlier than the predecessor's last-seen time (a missing time fails the
      guard); one-to-one; no distinct assertion or cooldown.
- [ ] 5.2 Merge with reason `source_succession`: earliest-created record survives (ties by uid)
      and takes the current id; source-owned metadata from the successor; facts per key by
      newest provenance; the successor's address; `merge_audit` details carrying the evidence
      and proving collections. Cap at `max_successions_per_run`.
- [ ] 5.3 Record `succession_review` decisions with reasons `corroborated_without_mac`,
      `mac_only`, `overlapping_hostname`, `shared_mac` and `not_one_to_one`.
- [ ] 5.4 An administrative unmerge of a succession records a distinct assertion for the pair.

## 6. Retired mark, hidden reads and grace delete (D5)

- [ ] 6.1 Mark a retired-only record in the retirement transaction (`source_retired_at` and
      `metadata.identity_state`).
- [ ] 6.2 Hide marked records from the default Ash device reads, inventory counts and the SRQL
      default device filter (`rust/srql/src/query/devices.rs`); add `include_retired` and its
      SRQL equivalent; show the mark and the deletion time on the device detail view.
- [ ] 6.3 `DeviceCleanupWorker`: soft-delete marked records past the grace period with
      `deleted_reason = "source_retired"` and `deleted_by = "system:source_retirement"`,
      releasing the address in the same transaction; hold records named by an open
      de-duplication task; apply the mass guard.
- [ ] 6.4 Make all three revival writers honor `source_retired`: `Device :gateway_restore`,
      `Device :restore`, and the raw `on_conflict` in `sync/device_writes.ex`. Grep for the
      attribute, not the action, to confirm there is no fourth.
- [ ] 6.5 Reconcile the pending copy of "Restore Soft-Deleted Devices" in
      `add-device-delete-guardrails` with this change's version before either is archived.

## 7. Reactivation and reissue (D6)

- [ ] 7.1 Resolve a reported id through the archive; return it to its archived holder or that
      holder's merge survivor only under D6's conditions, moving the row back, clearing the
      mark, restoring a tombstone through `:restore`, and recording `source_id_reactivated`.
- [ ] 7.2 Otherwise write a new record and record `source_id_reissued`, naming both.
- [ ] 7.3 Add an `unarchive` function for the remediation rollback, recording
      `source_id_reactivated`.

## 8. Address claims and released seeds (D7, D8)

- [ ] 8.1 Write `identity_observed_at` only from identity-bearing observations: a source sync
      carrying a current source id, an agent check-in, a discovery poll of the device itself.
- [ ] 8.2 `claim_address_from_holder/4`: a retired or `source_retired` holder yields; the
      newer-observation rule compares `identity_observed_at`, with null counting as older.
- [ ] 8.3 Soft-delete a qualifying released seed with `deleted_reason = "seed_released"` in the
      transaction that releases its address; keep the `ip_conflict` decision.
- [ ] 8.4 Replace the "stays live until expiry" comment in `sync/device_writes.ex` with the new
      rule.

## 9. Sweep restore and expiry (D12, D13, D14)

- [ ] 9.1 `SweepResultsIngestor`: restore a matched `stale_ephemeral` tombstone whatever its
      discovery sources; keep `restore_eligible?/1` for every other permitted reason; never
      restore `merged`, `source_retired` or `seed_released`.
- [ ] 9.2 Add `deleted_at IS NULL` to the availability and unavailability updates, and run the
      restore before them.
- [ ] 9.3 Correct the `EphemeralDeviceExpiry` module documentation and the Inventory Cleanup
      settings-page text so they say which tombstones a sighting restores.
- [ ] 9.4 Migration: redefine `platform.device_holds_strong_identifier/1` (or add a companion
      applied by both the candidate read and the delete) to hold a device whose metadata
      carries a non-empty `agent_id`, `armis_device_id`, `netbox_device_id` or
      `integration_id`, string or number. Bump the Helm expected migration version (2.4).
- [ ] 9.5 `EphemeralDeviceExpiry`: judge the guard on the eligible count from a read-only
      pre-pass; report `candidates`, `kept_by_evidence`, `kept_by_exclusion`, `eligible`,
      `expired` and `skipped_at_delete` in the result, the `DeviceCleanupWorker` log line and
      telemetry; make the refusal message print the eligible and live counts and say the
      override stays set until cleared.
- [ ] 9.6 Update callers, dashboards and docs that read the old `excluded` counter.
- [ ] 9.7 Confirm against the code whether a sweep re-creates a purged merged-away seed. The
      seed's uid derives from its address (`create_available_unknown_device/3`), so a sweep at
      that address after the purge may write a row under the merged-away uid, outside the
      redirect #4620 follows. If it does, add a switch and witness to the lifecycle model first
      (`SweepCreate` creates only a row that never existed), then fix it here.

## 10. Blocked-component accounting (D9)

- [ ] 10.1 Compute the evidence fingerprint per blocked component and store it in the identity
      decision's evidence; skip an unchanged component without re-attempting or re-recording it.
- [ ] 10.2 Add a reconciliation rule version constant, changed with every merge-rule change.
- [ ] 10.3 Add `succession_merges`, `succession_review` and `blocked_unchanged` to the run
      record, and stop counting blocked merges as errors.

## 11. Guardrails and telemetry

- [ ] 11.1 Telemetry: live-to-current ratio per source instance, records holding only retired
      ids, `source_retired` records, live released-seed shells, retirement and grace-delete
      refusals, and the reconciler's blocked counts.
- [ ] 11.2 Reserve the identity-bearing metadata keys in `MergeDeviceFacts` (`armis_device_id`,
      `integration_id`, `mac`, `ip`, `hostname`, `switch_port_attachment`) beside the existing
      ones.

## 12. Promote the model as each fix lands

- [ ] 12.1 In each fix pull request, remove its switch from `KnownBugs` and `CurrentBugs.tla`,
      delete its witness configuration and the knockout and trace witness configurations of the
      traces that demonstrate it, regenerate the affected traces with `DIRE_TRACE_WRITE=1`,
      model-check them, and make the property must-pass.
- [ ] 12.2 After the last fix, `KnownBugs` and `CurrentBugs` hold none of this change's switches,
      and both negative configurations still report `violation:NoFalseMerge`.

## 13. Remediation (D11)

- [ ] 13.1 Add the steps `source-id-retire`, `source-succession` and `released-seed-shells` to
      `DireRemediation`: dry-run by default with per-class counts (classes 1-8), `--execute` to
      write, batches of 500 by default, and the NDJSON manifest of archive row ids, merge audit
      ids, marked uids and tombstoned uids.
- [ ] 13.2 Rollback from the manifest, per action: `unarchive`, unmerge with a distinct
      assertion, clear the mark, `Device :restore`.
- [ ] 13.3 Verification checks V1-V8 as read-only queries run between batches. Show each one
      failing on a synthetic fixture built in the pre-fix state before trusting it.
- [ ] 13.4 Write the runbook under `docs/` (not `docs/docs/`), in ASCII: preconditions (the fix
      deployed), order, batches, checks, rollback, and confirming that every run started after
      the rollout finished.

## 14. Tests

- [ ] 14.1 Retirement: one absence, N within T, sustained absence, presence reset, non-exact
      collection, query change, no exact collections, mass refusal, TTL GC exemption.
- [ ] 14.2 Veto split: a new id with a known MAC gets its own record; a retired id still blocks
      the MAC-only backfill; corroborated succession passes the guard.
- [ ] 14.3 Succession: MAC and hostname, MAC and first-seen, MAC only, no MAC, cloned machines
      sharing a MAC and a hostname with overlapping lifetimes, a missing source time, not
      one-to-one, randomized MAC, before retirement, unmerge then rerun.
- [ ] 14.4 Mark and grace: immediate mark, agent-held record not marked, grace delete, review
      hold, a sweep that keeps answering, no revival through any of the three writers, and a
      revival audit row for every restore.
- [ ] 14.5 Reactivation and reissue, including a holder that now holds a current id and an
      update whose hostname fails D3's time guard.
- [ ] 14.6 Address claims: a retired holder yields; a sweep refresh does not make a holder
      newer; a released seed is tombstoned; a seed with an identifier row stays live.
- [ ] 14.7 Sweep restore: an expired sweep-only device returns with an audit row; an
      operator-deleted sweep-only device stays deleted and unchanged; a `source_retired` or
      `merged` tombstone is not restored.
- [ ] 14.8 Expiry: a metadata-only and a numeric metadata source id hold the device inside the
      delete statement itself; the guard judges eligible devices; each counter carries its
      own value.
- [ ] 14.9 Blocked accounting: an unchanged component is skipped, a retirement re-opens it, a
      rule-version change re-checks everything once, and blocks are not errors.
- [ ] 14.10 Remediation: dry run writes nothing; execute writes the manifest; each rollback
      restores the pre-run state; every verification check fails on the pre-fix fixture.
- [ ] 14.11 Extend the `add-hermetic-armis-dire-e2e` harness with the re-key scenarios.
- [ ] 14.12 Bump the selected-test counts in `build/integration_test_dispositions.bzl` for every
      integration test added to an existing file, and keep the web-ng DB lane counts in step.
- [ ] 14.13 Run `make test` (all TLC targets) and the affected integration lanes, and report any
      check not run.
