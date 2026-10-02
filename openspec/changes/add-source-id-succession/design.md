# Design: source-id retirement and corroborated succession

## Context

DIRE's identity rules come from `update-dire-strong-identity-goal`. A source-authoritative id
(the Armis device id, the NetBox device id) governs identity: two records holding different
values of one type in one scope are two devices, whatever MAC or address evidence they share.
That rule is right for two values the source reports *at the same time*, as with cloned
virtual machines. It is wrong for two values the source reports *one after the other* for the
same asset. The rule has no notion of a value the source no longer reports, so the retired
value keeps vetoing for ever.

The worked example used throughout is synthetic:

- An asset is reported by Armis as id 1001, with MAC `00:00:5e:00:53:01`, hostname
  `host01.example.com` and address `192.0.2.10`.
- DIRE creates record X for it.
- Armis later reports the same asset as id 2002, with the same MAC, hostname and first-seen
  time, and stops reporting 1001.

Today:

- Ingest creates record Y for 2002 and records a `source_override` decision.
- X keeps 1001, the MAC and, while the sweep keeps refreshing it, the address.
- `DuplicateSweep` finds X and Y through the MAC on every run, and `MergeEngine` refuses the
  merge as `source_authority_conflict`.
- X never ages out.

### What already exists

- **Exact source collections.**
  - Armis activates a source snapshot per collection (`ArmisSourceSnapshot.activate/3`).
  - The snapshot carries `accounting_status: "exact"`, the device and absent counts, the
    collection query hash and the activation time.
  - Each id has a `device_source_observations` row with `present`, `absent_since`, the
    source object id and the last reported hostname, MAC and address.
  - NetBox has no exact collections.
- **A dry-run classifier.** `Remediation.ArmisSourceIdentityRepair.dry_run/2` already splits a
  device's Armis ids into current and stale against the latest exact snapshot, and proposes
  `review_stale_ids_after_absence_grace`. Nothing applies it (`apply_eligible: false`).
- **An archive.** `platform.device_identifier_archive` (from migration
  `20260906150000_archive_proxmox_name_keyed_identifiers`) holds identifier rows with full
  provenance, `archived_at` and `archive_reason`.
- **Merge machinery.** `MergeEngine.merge_devices/3` writes `merge_audit` and can be reversed
  by `unmerge_device`. Reasons that start with `manual`, and `unmerge`, bypass its guards. The
  new reason must be neither.
- **A remediation framework.** `mix serviceradar.dire_remediation` is dry-run by default,
  executes on request, writes an NDJSON manifest of ids, and supports explicit-only steps.

## Goals and non-goals

Goals:

- One live record per source asset once retirement and succession have run.
- The record that survives keeps its history and holds the current id.
- A MAC never decides identity on its own.
- Nothing is lost: every retirement, succession and deletion is recorded and reversible.
- The formal model can express the failure and pins the fix.

Non-goals:

- Agent-id rotation (`add-agent-self-report-device-identity`).
- NetBox retirement, until NetBox produces exact collections.
- Re-keying telemetry rows to the survivor. The older-survivor rule keeps most history in place.
  Whether `MergeEngine` moves telemetry is a separate question.
- Re-opening MAC absorption at ingest.

## Decisions

### D1. "Current" is defined by exact collections, not by last-seen

A source-authoritative id is **retired** when both of these hold:

- it was absent from at least `source_retirement_absent_collections` (N, default 3)
  consecutive exact, activated collections of the source instance that owns its scope, all
  under one collection query hash;
- it was last reported at least `source_retirement_min_absence` (T, default 24 hours) ago.

Rules:

- **Only exact collections count.** Presence in any exact collection resets the count. A
  collection that is not exact, or that never activates, counts neither way. Collections flap,
  so one absence never retires an id.
- **A changed query hash restarts the count.** An id therefore needs N absences under one
  query. The effect of narrowing a query, which is retiring the ids it no longer covers, is
  bounded by the mass guard below.
- **Fail closed.** A type whose source has no exact collections, or an id whose scope cannot be
  tied to exactly one source instance, is never retired by absence.
- **Retirement runs after activation**, as a job enqueued by the activation of an exact
  collection. It never runs during ingest.
- **Mechanism.** Retiring moves the `device_identifiers` row to
  `platform.device_identifier_archive` in one transaction, with
  `archive_reason = "source_absent"`. It records a `source_id_retired` identity decision naming
  the device and the identifier, with the ids of the collections that proved the absence as
  evidence.
- **Mass guard.** A pass that would retire more than `source_retirement_max_fraction` (default
  0.5) of the live records holding ids from that source instance is refused. The refusal is
  logged at error level with the counts and emitted as telemetry. An operator override applies
  to one pass only and is cleared by the pass it lets through. This deliberately differs from
  `ephemeral_expiry_guard_override`, which stays set until an operator clears it, so one
  forced pass disables that guard for every later pass.
- **Settings** live in `DeviceCleanupSettings`, which is database-backed and edited on the
  Inventory Cleanup settings page:
  - N, T and the grace period (D5);
  - the guard fraction and its override;
  - `source_retirement_enabled`.

  Application env is not used: a key read only from `serviceradar_core`'s `runtime.exs` is
  silently absent in the deployed release.
- **Enabled by default.** The fix is the default, so the failure cannot recur on an
  installation nobody configured. The guard and the dry-run remediation bound the first run.

The classifier is `ArmisSourceIdentityRepair`, generalized into a source-neutral module that
reads the source-authoritative type map from `SourceAuthorityGuard` (`@source_identifiers`).
Its `current`, `stale` and `no_current_ids` buckets become retire inputs, with the N and T rules
added. The existing dry-run output stays available.

A source-authoritative id leaves the live identifier table by retirement, merge or unmerge, and
by nothing else. The identifier TTL garbage collection and the per-type cardinality cap proposed
in `refactor-device-identity-reconciliation` must exempt source-authoritative types. Removing one
silently would drop its veto with no record and no archive.

### D2. A retired id keeps barring ingest, and gives way only to corroborated succession

| Path | Current id of another value | Retired id of another value |
| --- | --- | --- |
| Ingest match (`SourceAuthorityGuard` at resolve time) | not a match: new record, `source_override` decision | not a match: new record, `source_override` decision |
| `MergeEngine` automatic merges (`identifier_backfill`, alias, gateway) | refused | refused |
| `MergeEngine` `source_succession` merge (D3) | refused | allowed when D3's corroboration holds |
| Administrative merge (`manual*` reasons) | operator decides | operator decides |

The guard therefore consults the archive as well as `device_identifiers`. A record holds or held
a value of type `t` if either table has a row for it in that scope.

Model checking (D10) added two consequences:

- **Equal values still conflict.** Two records conflict when each holds or held a value of type
  `t`, even the same value. A value has one holder at a time, so two records' current values
  always differ. A value that the archive keeps for one record while another record holds it now
  was re-issued to another asset (D6). The guard's test is therefore "both records have a history
  of the type", not "their values differ".
- **Archived rows anchor.** Every check that asks whether a record is anchored by an identifier
  counts archived rows: the seed adoption in `DeviceWrites` (`anchored_device_uids/1`, read by
  `provisional_ip_seed?/2`) and D8's released-seed rule. A record holding only retired ids is not
  an anchorless seed. Otherwise a new record for another device's id adopts it, and one record
  describes two devices.

Two simpler alternatives were rejected:

- **Letting retirement simply drop the veto.** After retirement the old record no longer holds
  1001, so the next sync of 2002 would match it through the MAC at ingest. That is MAC-only
  absorption: the behavior before the source-authority guard, and the cloned-VM hazard. In the
  model it is `retired_ids_forgotten`, and it violates `NoFalseMerge` (D10).
- **Deciding succession at ingest.** Whether an id is absent is known only after a collection
  activates, and one absence is not retirement (D1).

### D3. Succession is corroborated, one-to-one, and runs in the reconciler

`DuplicateSweep` gains a succession pass that runs after its duplicate pass on the same
schedule. Definitions:

- A **predecessor** is a live record all of whose source-authoritative ids of type `t` are
  retired.
- A **successor** is a live record holding a current id of type `t` in the same scope.

They converge when all of the following hold:

1. **A shared universal MAC.** Both records report a MAC that is universally administered,
   unicast, not all-zero and not broadcast. The MAC may come from identifier rows, interface
   MACs, the device MAC attribute, or the source's last observation of the predecessor and
   current observation of the successor. It must link the predecessor to no other record
   holding a current id of type `t`.
2. **Corroboration.** The predecessor's last source observation and the successor's current
   one agree on either of these:
   - the source first-seen time, compared at the source's precision;
   - the normalized hostname: lower-cased, trailing dot removed, the full name compared.

   A hostname held by more than one current record of the source does not corroborate.
3. **One-to-one.** The predecessor has exactly one successor satisfying 1 and 2, and the
   successor exactly one predecessor.
4. **Permitted.** No distinct assertion covers the pair, and the merge cooldown permits it.

The merge itself:

- **Survivor.** The record created first survives, with ties broken by uid. In the usual case
  that is the predecessor. The other record is merged into it, so the current id moves to the
  survivor, and the merged-away uid redirects to the survivor through `merge_audit` as for any
  merge.
- **Attributes.**
  - Source-owned metadata keys come from the successor, because they describe the current id.
  - Facts carrying provenance merge per key, newest `updated_at` first.
  - Every other attribute keeps today's survivor-wins rule (`preserve_survivor_attributes`).
  - The survivor takes the successor's address when the successor holds one.
- **Recording.**
  - Reason `source_succession`.
  - `merge_audit` details carry the shared MAC, the corroborating field, the retired and
    current ids, and the collection ids that proved the retirement.
  - The merge is not an identity decision, because it is not a block, so it opens no
    de-duplication task.
- **Reversal.** An administrative unmerge of a `source_succession` merge restores both records.
  It also records a distinct assertion for the pair, so the next run does not merge them again.
- **Cap.** `max_successions_per_run`, default 200, alongside the existing merge cap.
- **Re-validation.** Each pair is re-checked inside its merge transaction. The model merges one
  pair per step, and a list computed at the start of a run can be stale after the run's first
  merge.

Hostname agreement only corroborates. It never merges on its own, so "Hostname Agreement Is Not
Identity" stands.

### D4. Weaker evidence goes to review

These cases are not merged automatically. Each one records a `succession_review` identity
decision with a reason, which opens or updates the de-duplication task for the device set and
puts it in the existing review queue at `/devices/deduplication`:

| Case | Reason |
| --- | --- |
| Equal hostname and first-seen time, no shared universal MAC | `corroborated_without_mac` |
| Shared universal MAC, neither field agrees | `mac_only` |
| The MAC links the predecessor to more than one current record | `shared_mac` |
| More than one predecessor or successor (including multi-generation re-keys) | `not_one_to_one` |

An operator resolves the task with the existing merge, distinct and dismiss actions.

### D5. A retired record with no successor is hidden, then deleted after a grace period

When a retirement leaves a live record **retired-only**, the same transaction sets the
record's `source_retired_at` and `metadata.identity_state = "source_retired"`. A record is
retired-only when all of these hold:

- every source-authoritative id it holds is retired;
- it holds no agent identifier and no current source-authoritative id of another type;
- its last identity-bearing observation (D7) is at least T old;
- no operator created it.

Behavior while marked:

- **Mark is authoritative.** `source_retired_at` is the authority, a column so that
  default-read filters and the grace query can use an index. `identity_state` mirrors it for
  existing readers and is already a reserved key of `MergeDeviceFacts`.
- **Hidden by default.** Marked records are hidden from the default Ash device reads, from SRQL
  `in:devices` queries without an explicit filter, and from inventory counts. A filter
  (`include_retired`, and the SRQL equivalent) shows them. Device detail by uid still shows them,
  with the time they will be deleted.
- **Still a candidate.** They remain succession and reactivation candidates.
- **Grace delete.** After `source_retired_grace` (default 7 days), a `DeviceCleanupWorker` pass
  soft-deletes them through `Device :soft_delete` with `deleted_reason = "source_retired"` and
  `deleted_by = "system:source_retirement"`. The same transaction releases the address. The mass
  guard of D1 applies to the pass.
- **Held from deletion.** A marked record named by an open de-duplication task is not deleted
  while the task is open.
- **Evidence never revives.** Sweep, address-only and MAC-only sightings never clear the mark,
  extend the grace, or restore the tombstone. The repository hard rule names three revival
  writers:
  - `Device :gateway_restore`;
  - `Device :restore`;
  - the raw `on_conflict` in `sync/device_writes.ex`.

  All three must honor the `source_retired` reason, and `device_revival_audit` records any
  restore.
- **Event-driven.** Marking happens when a retirement event occurs. After an operator restores a
  record, it is not marked again until another id of its own is retired.

The mark comes before deletion, rather than deleting at once, for two reasons. The revival paths
make a deletion that is undone silently worse than no deletion. A grace period also leaves room
for succession and review.

### D6. A retired id presented again

The archive is indexed by `(identifier_type, identifier_value, partition)`, and resolution
consults it. When a source reports a retired id again:

- **Reactivation.** The id returns to the record that held it when it was retired, or to that
  record's merge survivor. This needs all of the following:
  - exactly one such record qualifies;
  - the record holds no unretired id of that type, that is, no `device_identifiers` row of the
    type. Whether the source still reports that id does not matter. A record that took a
    device's new id by succession still holds it after the source switches back to the old one,
    and reactivating the old id there would leave one record holding two ids of the type;
  - the update agrees with the archived observation on a universal MAC;
  - the update agrees on the first-seen time or the hostname.

  The reactivated record is the update's match, as if it had never lost the id. Resolution must
  not fall back to the uid the id derives: that uid names the record that first held the id,
  which after a re-issue is another device's record.

  The archive row is moved back. A `source_retired` mark is cleared, and a tombstone is
  restored through the audited restore path. The decision is recorded as `source_id_reactivated`.
- **Re-issue.** Otherwise the update is written as a new record, and a `source_id_reissued`
  decision names both records and opens a review task. The new record never joins the old one
  automatically. When a record already carries the uid the id derives, live or merged away, the
  new record gets a fresh uid; writing to the derived uid would land the update on the old
  record.

The archive never merges two live records. This pins the model's `FreshIds = FALSE` case: a
source that re-issues an old id to a different asset produces a review task, not a false merge.

### D7. A stale or retired holder does not keep the address

`claim_address_from_holder/4` changes in two ways:

- **A retired holder yields.** A record holding a current source id takes the address from a
  holder that is `source_retired`, or whose source-authoritative ids are all retired, whatever
  their timestamps.
- **The newer-observation rule compares identity-bearing observations.** Between two
  identified records it compares each record's `identity_observed_at`. That new column is
  written only by observations that carry a strong identifier as the device's own report:
  - a source sync carrying a current source-authoritative id;
  - an agent check-in;
  - a discovery poll of the device itself.

  Sweeps, ARP/census sightings and address-only sightings never advance it. A holder with no
  recorded value counts as older. The column needs no backfill.

Today `observed_after?` compares the incoming source time with `last_seen_time`, which the sweep
refreshes, so a holder the source abandoned keeps winning.

### D8. A released seed is retired in the same transaction

When an identified device takes the only address of an anchorless provisional seed, the seed is
soft-deleted in the same transaction with `deleted_reason = "seed_released"`. The seed qualifies
when all of these hold:

- it has no identifier rows, current or archived (D2);
- its discovery sources are only `sweep`;
- it holds no other address.

The `ip_conflict` decision is still recorded. A seed that carries anything more stays live and
keeps today's behavior.

**This is the fix for the shell pile-up; expiry is not.** A released shell is never seen again:
it has no address for a sweep to answer on, so its last-seen time stays at the moment it was
released. With ephemeral expiry disabled it lives for ever. With expiry enabled it lives exactly
one expiry window, so the live population settles at about the window times the daily release
rate; a shorter window shrinks the pile but never empties it, and shortens the window for every
genuinely ephemeral device as well. Retiring the seed in the transaction that releases its
address is the only rule under which no shell is ever live, which is what `NoAddresslessShell`
(D10) and verification check V4 (D11) state. The existing pile is the remediation's
`released-seed-shells` step.

The seed is tombstoned rather than merged into the claimant. A seed is named by its address, so
redirecting its uid to the claimant would make that address resolve to the claimant for ever.
That is address-as-identity, which D1 of the strong-identity goal forbids. If the address later
answers a sweep with no holder, a seed comes back through the normal discovery path, which
records the revival.

### D9. Blocked components carry an evidence fingerprint

For each blocked component (a source conflict, a guard block or a component block),
`DuplicateSweep` computes a fingerprint over:

- the sorted device set;
- each device's live and archived identifier rows (type, value, partition);
- the distinct assertions covering the set;
- a reconciliation rule version that changes whenever the merge rules change.

It stores the fingerprint in the evidence of the identity decision for that set. On the next
run, a component whose fingerprint is unchanged is skipped. It is neither re-attempted nor
re-recorded, so the decision's occurrence count measures evidence changes rather than runs.

The fingerprint changes whenever its inputs do:

- a retirement (D1) changes the archive state, so a pair blocked by a since-retired id is
  re-evaluated and can succeed;
- a deploy that changes the rules changes the rule version, so everything is re-checked once.

Blocked merges are reported as blocked, never as errors. The run record gains:

- `succession_merges`;
- `succession_review`;
- `blocked_unchanged`;
- the blocked count, kept separate from `errors`.

### D10. The formal model

These changes go in `formal/dire`. They are specified here as tasks and land before any code
(tasks 1.x).

**Resolution model (`DireResolution.tla`).**

- `srcOf` becomes a variable, initialized from the constant `SrcOf0`.
- `Rekey(h, a)` gives a device a new id. It is gated by the constant `Rekeys`, so every
  existing environment keeps its state space. Under the constant `FreshIds`, a re-key uses an
  id never issued before.
- A ghost `recFs` records, per record, the physical device whose source first-seen time it
  carries. It stands for the first-seen and hostname corroboration.
- `Collect` marks current ids present. Each absent id carries a coarse clock in
  `Fresh | Stale`. One `Stale` value stands for "N collections and T elapsed", so the clock
  does not blow up the state space.
- `RetireAbsent(a)` archives a stale absent id.
- The reconciler's `Succeed` and `Review` actions perform D3's succession and record D4's cases.
- Ingest consults the archive (D2).
- Each record carries an identity-observation freshness value, which the sweep never refreshes
  (D7).

**New properties.**

- `OneSourceRecordPerDevice`: at most one live record holding a source id describes each
  physical device. It is checked **at rest**, in states where neither `RetireAbsent` nor
  the reconciler can change anything. Resolve-time succession cannot satisfy it alone: a scratch
  run of a shared-MAC re-key showed that only absence-based retirement converges there.
- `CurrentSourceIdResolves`: a device's current source id, once owned, is owned by the device's
  canonical record.
- `SuccessionIsCorroborated`, an action property: every `source_succession` merge had a shared
  universal MAC, corroboration and a one-to-one pairing. A MAC alone never merges.
- `NoMergeOfCurrentSourceIds`, an action property: no merge joins two records holding distinct
  current source ids. This is `DistinctSourceIdsNeverMerge` restated over current ids, which is
  what the amended requirement says.
- `NoAddresslessShell`: no live record holds neither identifiers nor an address.

**Defect switches for today's code.** Each goes in `KnownBugs` and `CurrentBugs.ResolutionBugs`
only after its counterexample is confirmed against the Elixir code, as "Known DIRE Defects Have
Witness Configurations" requires.

| Switch | Witness | Expected |
| --- | --- | --- |
| `retired_source_id_vetoes` | `resolution_witness_retired_source_id_vetoes` (environment `armis_rekey`) | `violation:OneSourceRecordPerDevice` |
| `stale_holder_keeps_address` | `resolution_witness_stale_holder_keeps_address` | `violation:ObservedAddressHeld` |
| `released_seed_stays_live` | `resolution_witness_released_seed_stays_live` | `violation:NoAddresslessShell` |

A scratch copy of the model with the re-key action reproduced the split in five steps, with
abstract constants only:

1. Lease the device an address.
2. Armis observes id `a1` with MAC `m1`.
3. Re-key to `a2`.
4. Armis observes `a2` with `m1`.
5. Two live records now describe one device.

The same scratch runs passed `fix_rekey` and `fix_shared_mac_corroborated` against every
committed property.

**Rejected alternatives.** A new constant, `Unsafe`, holds design alternatives rejected for
identity safety. `ASSUME Unsafe \subseteq UnsafeAlternatives` constrains it, and no goal or
trace configuration ever sets it. Each alternative has a negative configuration:

| Alternative | Configuration | Expected |
| --- | --- | --- |
| `mac_only_succession` (no corroboration) | `resolution_unsafe_mac_only_succession`, environment `armis_rekey_shared_mac` | `violation:NoFalseMerge` |
| `retired_ids_forgotten` (archive not consulted, `FreshIds = FALSE`) | `resolution_unsafe_retired_ids_forgotten`, environment `armis_reissued_ids` | `violation:NoFalseMerge` |

**New environments and configurations.**

- Environments:
  - `armis_rekey`: one device, observers Armis and Sweep, re-keys on.
  - `armis_rekey_shared_mac`: two devices sharing a MAC, re-keys on.
  - `armis_reissued_ids`: `FreshIds = FALSE`.
- Each environment gets a `resolution_goal_*` configuration that checks every existing goal
  property plus the new ones.
- `resolution_vacuity_succession` expects `violation:NeverSucceeds`, proving that the goal does
  merge a re-keyed pair.

**Lifecycle model (`DireLifecycle.tla`).**

- `Expire` is gated by a new constant, `ExpiryEnabled`.
- `Reasons` gains `expired`, `source_retired` and `seed_released`, so `Expire` no longer records
  the generic `other`.
- Each record carries a sweep-only discovery flag. `SweepRestore` follows the code's rule: it
  restores a tombstone that has a non-sweep discovery source, or (once D12 lands) an `expired`
  one. A new `SweepRefresh` action stands for the sweep's availability write.
- New actions:
  - `MarkRetired`;
  - `GraceDelete`;
  - an evidence sighting of a `source_retired` tombstone.
- Properties:
  - `RetiredTombstoneStaysDeleted`: no evidence path restores a `source_retired` tombstone.
  - `SweepWritesOnlyLiveRecords`, an action property: a sweep write changes only a record that
    is live after the step.
  - `ExpiredDeviceReturns`, an action property: a sweep that matches an `expired` tombstone
    restores it.
  - `lifecycle_goal_no_expiry` sets `ExpiryEnabled = FALSE` and must pass, so the goal does not
    rest on expiry silently.
  - `lifecycle_vacuity_grace_delete` expects `violation:NeverGraceDeletes`.
- Defect switch, under the same confirmation rule as the resolution switches:

  | Switch | Witness | Expected |
  | --- | --- | --- |
  | `sweep_refreshes_expired_tombstone` | `lifecycle_witness_sweep_refreshes_expired_tombstone` | `violation:ExpiredDeviceReturns` |

**Traces.** Both traces are corrected, and one is added:

- `src_attach_shared_mac` stays the cloned-VM regression: two devices, two current ids, kept
  separate. That part is correct and must not change. It is extended: the first device then
  leaves the source for N exact collections. The expected result is that its id retires and
  its record is marked `source_retired`, **not** merged into the other device, because their
  first-seen times and hostnames differ.
- A new trace, `src_rekey_succession`, records one device re-keyed from `a1` to `a2`, then N
  collections without `a1`, then reconciliation.
- `armis_moves_onto_sweep_seed` expects the released seed to be soft-deleted with reason
  `seed_released`.
- A new lifecycle trace, `expired_sweep_only_returns`, records a sweep-only device that
  expires and then answers a sweep. The expected result is that it is restored, with an audit
  row and a bumped revision.

Until each fix lands, each of these traces demonstrates its switch with a knockout configuration
(`assert_golden!(demonstrates: ...)`). The fix pull request regenerates it.

**The gate.** If TLC finds a counterexample to a goal property in the new goal configurations,
the design returns to this document for revision before any code is written.

**Revisions the gate made.** The first runs of the new goal configurations found three
counterexamples. Each was fixed in this document before any code:

- `armis_rekey_shared_mac`, `NoFalseMerge`: a record whose only source id had retired held no
  identifier rows, so a new record for the other device's new id adopted it as a provisional
  seed. Archived rows now anchor (D2).
- `armis_reissued_ids`, `DistinctSourceIdsNeverMerge`: reactivation conditioned on "holds no id
  the source reports" put a retired id back on a record that still held the device's newer id
  after a succession. The condition is now "holds no unretired id" (D6).
- `armis_reissued_ids`, `NoFalseMerge`: a reactivated record that was not the update's match let
  the write fall back to the uid the id derives, which named the other device's record. The
  reactivated record is now the match (D6).

With the archive, two records can carry the same value of a type, so the source conflict test
also changed from "different values" to "both records have a history of the type" (D2).

### D11. Remediation

The steps are operator-invoked, dry-run first, and run only after the fix is deployed. They are
added to `DireRemediation`. Every class is recounted in each dry run, because the counts move
with every collection.

| Class | Records | Disposition | Step |
| --- | --- | --- | --- |
| 1 | live records holding a retirable id beside a current one (multi-id) | retire the stale ids, keep the record | `source-id-retire` |
| 2 | predecessor and successor sharing a universal MAC and a hostname | succession merge | `source-succession` |
| 3 | predecessor and successor sharing a universal MAC and a first-seen time only | succession merge | `source-succession` |
| 4 | a MAC only, or a hostname and first-seen time without a MAC | review task | `source-succession` (opens tasks only) |
| 5 | retired-only records with no candidate | mark `source_retired`; the grace delete follows | `source-id-retire` |
| 6 | sets that are not one-to-one | review task | `source-succession` (opens tasks only) |
| 7 | released-seed shells (no address, no identifiers, sweep-only) | soft-delete, reason `seed_released` | `released-seed-shells` |
| 8 | one source id carried in metadata by several live records | review only; `armis-dups` stays disabled | none |

Rules:

- **Order.** `source-id-retire`, then `source-succession` (which needs the retirements), then
  `released-seed-shells`.
- **No guard bypass.** Merges use reason `source_succession`, never `manual_*`. After
  retirement, the guard permits exactly the corroborated merges.
- **Batches.** Each batch, by default 500 actions, appends to the NDJSON manifest:
  - archive row ids;
  - merge audit ids;
  - marked uids;
  - tombstoned uids.
- **Rollback, per action, from the manifest:**

  | Action | Rollback |
  | --- | --- |
  | Retirement | `unarchive`, a new function that moves the row back and records `source_id_reactivated` |
  | Succession merge | unmerge, which also asserts the pair distinct |
  | Mark | clear `source_retired_at` and `identity_state` |
  | Tombstone | `Device :restore`, audited by the revival trigger |

  No pre-run backup is required.
- **Verification** is read-only and runs between batches. Each check must fail on the data as
  it is before the run starts; a check that cannot fail is not trusted:

  | Check | Passes when |
  | --- | --- |
  | V1 | live records holding a source id, divided by the ids present in the latest exact collection, is at most 1.02 |
  | V2 | no live, unmarked record holds a source id that is absent past the threshold |
  | V3 | no source id appears in the metadata of more than one live record, apart from the reviewed class 8. The identifier-table form of this check is zero by construction, so it cannot fail. |
  | V4 | no released-seed shells are live, and none are live after the next sweep cycle |
  | V5 | V1-V4 still pass after two collections and one sweep cycle that all started after the batch finished |
  | V6 | `device_revival_audit` has no row for a uid in the manifest |
  | V7 | the reconciler's next runs report no errors from blocks and no failed runs |
  | V8 | no `source_succession` merge joined two ids that are both present in the latest collection |

A runbook under `docs/` covers the preconditions, the order, batches, checks and rollback.

### D12. A sweep restores an expired sweep-only device, and never writes to a tombstone

Ephemeral expiry promises that an expired device which is seen again comes back: the
`EphemeralDeviceExpiry` module documentation says so ("a sweep, a sync"), and so does the
Inventory Cleanup settings page ("Expired and deleted devices are restored if they are
discovered again"). For a sweep-only device, which is the usual expiry candidate, the code does
not:

- `SweepResultsIngestor.restore_eligible?/1` restores a tombstone only when the device has a
  discovery source other than `sweep`.
- The sweep's address lookup (`DeviceLookup`, with `include_deleted: true`) prefers a live
  holder and otherwise falls back to a tombstone, so the returning host resolves to its own
  expired record and no new seed is created.
- The availability `UPDATE` in `update_device_statuses_available/3` has no `deleted_at IS NULL`
  predicate, so the sweep refreshes the tombstone's `last_seen_time` and `is_available`.

A returning sweep-only host therefore refreshes an invisible tombstone until the purge removes
it, one retention period later, and only then reappears as a new seed. With a short expiry
window, a real host that misses sweeps for a day or two disappears from inventory for a whole
retention period.

The change:

- **A sweep restores a `stale_ephemeral` tombstone it matches**, whatever the device's
  discovery sources, through `Device :restore`, which bumps `identity_revision` and leaves a
  `device_revival_audit` row. Expiry is a judgment that the device is gone; an answer on its
  address disproves it.
- **Other reasons keep their rules.** A `merged` tombstone redirects to its survivor. A
  `source_retired` (D5) or `seed_released` (D8) tombstone is never restored by a sweep, and a
  `seed_released` tombstone holds no address for a sweep to match. A sweep-only device that an
  operator deleted is not restored by a sweep, as today. Sweep revival of an operator's
  deletion is the failure the repository's tombstone hard rule records, so this change does not
  widen it.
- **No sweep write lands on a tombstone.** The availability and unavailability updates gain a
  `deleted_at IS NULL` predicate, and the restore runs before them, so a restored device takes
  the sighting and an unrestored tombstone is left exactly as it was.
- **The text becomes true.** The module documentation and the settings-page text are corrected
  to say which tombstones a sighting restores and which it does not.

Rejected: excluding `stale_ephemeral` tombstones from the lookup fallback so the sweep creates a
fresh seed. The device would lose its uid and history, and until the purge the tombstone and the
new seed would hold the same address.

The lifecycle model's `SweepRestore` restores any non-merged tombstone, so it is more permissive
than the code and could not see this. D10's lifecycle tasks give records a sweep-only discovery
flag and model the code's rule.

### D13. The SQL strong-identifier hold covers source ids recorded only in metadata

Ephemeral expiry decides in two stages. The candidate read and the soft delete's `UPDATE ...
WHERE` apply `platform.device_holds_strong_identifier/1`, which reads only `device_identifiers`
and `device_interface_macs`. A second, in-memory check (`strong_attributes?/1`) also reads the
device's `mac` attribute and metadata.

A device whose source-authoritative id survives only in its metadata, because its identifier
row was garbage-collected or never written, passes the SQL function. It is protected by the
in-memory check alone, and the delete statement would not stop its expiry. That is correct
today, but it rests on one parse: if `Ids` ever stopped reading the value, for example a numeric
JSON value where it expects a string, nothing in SQL would hold the device.

The change: a migration replaces the function (or adds a companion that the candidate read and
the delete both apply) so that it also holds a device whose metadata carries a non-empty
`agent_id`, `armis_device_id`, `netbox_device_id` or `integration_id`, as a JSON string or
number. The SQL hold deliberately skips the in-memory check's admission rules (for example the
rejection of a purely numeric `integration_id`): a hold that keeps too much is safe, and the
in-memory check remains as the second stage. The migration redefines a function and backfills
nothing.

Records that this holds, and that hold no identifier row, stay outside retirement (D1 works on
identifier rows); see the open question below. A retired-only record (D5) is also held from
expiry by its metadata, which is intended: the grace delete, not expiry, removes it.

### D14. Expiry reports what it counts

The names in the expiry guard, logs and telemetry do not match what they count:

- `mass_expiry_guard/3` counts the stage-1 candidates of the whole pass, before either keep
  check, and its refusal says the pass "would expire up to" that many devices. Where many stale
  devices are held by metadata, the count is far larger than what the pass would delete, so the
  guard refuses a small pass and invites the persistent override.
- The pass result's `excluded` counts the devices kept by stage 2 (attribute and metadata
  evidence, and the exclusion query, together). An operator reads it as matches of the
  exclusion query.

The change:

- **The guard judges what the pass would expire**: the stage-1 candidates minus those kept by
  either stage-2 rule, computed by a read-only pass over the same keyset pages before any
  delete. It still compares that count with all live devices.
- **Separate, honestly named counters**, used alike in the result map, the
  `DeviceCleanupWorker` log line, telemetry and the refusal message:
  - `candidates`, the stage-1 count;
  - `kept_by_evidence`, kept by attribute or metadata evidence;
  - `kept_by_exclusion`, kept by the exclusion query;
  - `eligible`;
  - `expired`;
  - `skipped_at_delete`, eligible devices the `UPDATE`'s re-check refused.
- **The refusal message** prints the eligible and live counts and says that
  `ephemeral_expiry_guard_override` stays set until it is cleared.

Rejected: keeping the stage-1 count as a conservative bound under an honest name. It is honest,
but it keeps refusing passes that would delete little, which trains operators to set an override
that then disables the guard for good.

### D15. Delivery order

1. Formal model and traces (D10), as a model-only pull request that records today's defects.
2. Schema, settings, retirement and the veto split (D1, D2), including the archive-aware guard.
3. Succession and review (D3, D4).
4. The retired mark, the hidden reads and the grace delete (D5), and reactivation (D6).
5. Address claims and released seeds (D7, D8).
6. Blocked-component accounting (D9), the guardrails and the reserved keys.
7. Sweep restore of expired devices and the expiry hold and counters (D12-D14). These do not
   depend on 2-6 and may land in any order with them.
8. Remediation and the runbook (D11), run by an operator after 2-7 are deployed.

Each fix pull request removes its switch, promotes its property and regenerates its traces, as
"Fixing a Modeled Defect Promotes Its Invariant" requires.

## Risks and trade-offs

- **A source that re-issues ids to different assets.** D6 sends the reissued id to review, and
  the model's `armis_reissued_ids` goal pins it.
- **A collection that is exact but wrong**, for example a misconfigured query, could retire
  many ids at once. Three things bound it:
  - the N and T thresholds;
  - the query-hash reset;
  - the mass guard.

  Retirement is also reversible.
- **Survivor metadata that is briefly stale.** Source-owned keys come from the successor (D3),
  and the next sync overwrites the rest.
- **Hidden records still answer sweeps** during the grace period. They cannot keep an address
  against a current record (D7) or be revived by evidence (D5).
- **Telemetry history** recorded under a merged-away uid stays under it unless `MergeEngine`
  moves it. The older-survivor rule keeps most history on the survivor.
- **Expired sweep-only devices come back** (D12) as soon as they answer again. That is what
  expiry always promised. A short expiry window now means "hidden while unreachable", not
  "hidden for a retention period".

## Open questions

- When NetBox gains exact collections, enabling NetBox retirement is a settings change plus a
  test. No spec change should be needed.
- A source id that appears only in device metadata, with no identifier row, is outside
  retirement and succession. D13 makes its hold on expiry durable, so such a record stays until
  this is decided. Check classes 1-5 first, then decide whether to restore the identifier row
  from the latest exact collection or to retire the metadata value by the same absence rule.
