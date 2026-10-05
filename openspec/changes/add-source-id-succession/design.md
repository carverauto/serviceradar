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
- it was last reported at least `source_retirement_min_absence_hours` (T, default 24) hours ago.

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
- **The derived integration id moves with it.** The record's `integration_id` derived from the
  retired id (`IntegrationIdentity.scoped_device_id/3`, in the same scope) is archived in the
  same transaction and named in the decision's evidence. An integration id governs identity only
  through the typed id it accompanies; left behind, it would keep matching updates for the
  retired id and hand it back to the record without D6's checks. Reactivation (D6) moves both
  rows back. The model's one source id stands for both rows.
- **Counting.** Absences are counted when an exact collection activates, inside the activation
  transaction, in `platform.source_identifier_absences`: one row per source object id that a
  live record holds and the collection did not report, with the count, the query hash and the
  proving collection ids. Presence in an exact collection deletes the row, and a collection
  under a different query restarts the count at 1. "Last reported" is the later of the id's
  source observation and its identifier row's last sighting, so a report on any ingest path
  holds the id. The retirement pass reads these rows and checks the rule again under the
  device's locks.
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

The classifier is `ArmisSourceIdentityRepair`, generalized into a source-neutral module
(`Remediation.SourceIdentityRepair`) that reads the source-authoritative type map from
`SourceAuthorityGuard` (`@source_identifiers`). Its `current`, `stale` and `no_current_ids`
buckets become retire inputs, with the N and T rules added. The existing dry-run output stays
available.

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
   - the source first-seen time, compared at the source's precision. Equal first-seen times
     corroborate on their own;
   - the normalized hostname (lower-cased, trailing dot removed, the full name compared), when
     the successor's first-seen time is no earlier than the predecessor's last-seen time.

   The time guard separates a re-key from a clone. A re-keyed device appears under its new id
   only after the source last saw it under the old one. Cloned machines share a hostname while
   both are in the source, so the successor was first seen while the predecessor was still
   being seen. A missing time on either side fails the guard.

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
- **Mark.** A predecessor that survives is often marked `source_retired` (D5). The merge clears
  the mark in the same transaction, because the survivor now holds the current id.
- **Recording.**
  - Reason `source_succession`.
  - `merge_audit` details carry the shared MAC, the corroborating field, the retired and
    current ids, and the collection ids that proved the retirement.
  - The merge is not an identity decision, because it is not a block, so it opens no
    de-duplication task. An open task for exactly the merged pair is marked merged into the
    survivor, whatever decision opened it (see "Hostname agreement at ingest").
- **Reversal.** An administrative unmerge of a `source_succession` merge restores both records.
  It also records a distinct assertion for the pair, so the next run does not merge them again.
- **Cap.** `max_successions_per_run`, default 200, alongside the existing merge cap.
- **Re-validation.** Each pair is re-checked inside its merge transaction. The model merges one
  pair per step, and a list computed at the start of a run can be stale after the run's first
  merge.

Hostname agreement only corroborates. It never merges on its own, so "Hostname Agreement Is Not
Identity" stands.

**Accepted residual.** Some clones look exactly like a re-key, and no rule over these fields can
tell them apart. Two cases:

- A clone that the source first sees after it last saw its twin: the twin left first, and the
  clone shares its MAC and hostname.
- A clone that the source reports under an id it re-issued.

The model's `armis_clones` environment checks the guarded rule on two clones whose lifetimes
overlap. The residual cases are listed under "What the models do not express" in
`formal/dire/README.md`. An operator undoes such a merge with an administrative unmerge, which
records a distinct assertion for the pair.

### D4. Weaker evidence goes to review

These cases are not merged automatically. Each one records a `succession_review` identity
decision with a reason, which opens or updates the de-duplication task for the device set and
puts it in the existing review queue at `/devices/deduplication`:

| Case | Reason |
| --- | --- |
| Equal hostname and first-seen time, no shared universal MAC | `corroborated_without_mac` |
| Shared universal MAC, neither field agrees | `mac_only` |
| Shared universal MAC and hostname, but the time guard fails (the successor was first seen before the predecessor was last seen, or a time is missing) or another current record of the source holds the hostname | `overlapping_hostname` |
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
- **Hidden by default.** Marked records are hidden from the inventory read (`Device :inventory`,
  which the device list and inventory counts read through), from SRQL `in:devices` queries
  without an explicit filter, and from inventory counts. A filter (`include_retired`, and the
  SRQL equivalents `include_retired:true` and `source_retired:`) shows them. The plain
  `Device :read` still returns them: identity resolution, the review queue, bulk actions and
  every update's atomic re-read must keep seeing a record that is still a candidate (below).
  Device detail by uid still shows them, with the time they will be deleted.
- **Still a candidate.** They remain succession and reactivation candidates.
- **Grace delete.** After `source_retired_grace_days` (default 7), a `DeviceCleanupWorker` pass
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
- **Cleared by identity.** A marked record that gains an agent identifier or a
  source-authoritative id is no longer retired-only, so the transaction that registers the
  identifier clears the mark. That covers a reactivation (D6), a `source_succession` merge into
  the record (D3), and an ingest that registers such an identifier on it. MAC and address
  evidence registers neither, so evidence still never clears the mark. The grace delete
  therefore never deletes a record holding one of these identifiers; the lifecycle model checks
  this as `MarkedHoldsOnlyMacs`. A MAC never retires, so a MAC the record holds neither
  withholds the mark nor clears it: the record keeps it while marked and as a tombstone, and it
  is the hardware evidence a reactivation needs (D6).

The mark comes before deletion, rather than deleting at once, for two reasons. The revival paths
make a deletion that is undone silently worse than no deletion. A grace period also leaves room
for succession and review.

### D6. A retired id presented again

The archive is indexed by `(identifier_type, identifier_value, partition)`, and resolution
consults it. When a source reports a retired id again, whatever the reason it retired:

- **Reactivation.** The id returns to the record that held it when it was retired, or to that
  record's merge survivor. This needs all of the following:
  - exactly one such record qualifies. A record merged away is followed to its survivor, which
    holds the archived rows; a tombstone that was not merged away, including a `source_retired`
    one, is a candidate;
  - the record holds no unretired id of that type in the id's scope (its identifier
    partition), that is, no `device_identifiers` row of the type there. Whether the source
    still reports that id does not matter. A record that took a device's new id by succession
    still holds it after the source switches back to the old one, and reactivating the old id
    there would leave one record holding two ids of the type;
  - the update shares a hardware MAC (universally administered and unicast) with the record:
    the record's own MAC, its MAC identifiers, its interface MACs, or the MAC the source last
    reported for the id. The source's observation counts only as it stood when the id retired;
    one the source refreshed since describes whatever reports the id now;
  - the update agrees on the first-seen time or the hostname, the one the source last reported
    for the id or the record's own. A hostname corroborates under D3's time guard: the update's
    first-seen time must be no earlier than the archived id's last-seen time.

  The source's first-seen and last-seen times travel with the identifier row into the archive,
  in its metadata. A row archived before identifier rows carried them is judged on the record's
  first-seen time, and only an equal first-seen time corroborates it: with no last-seen time a
  hostname cannot pass the time guard.

  The reactivated record is the update's match, as if it had never lost the id. Resolution must
  not fall back to the uid the id derives: that uid names the record that first held the id,
  which after a re-issue is another device's record.

  The newest archive row of the id, and the integration id derived from it, are moved back. A
  tombstone is restored through the audited restore path first, releasing its address when
  another live record holds it, and the returned identifier clears a `source_retired` mark.
  The record's identity revision is bumped and the decision is recorded as
  `source_id_reactivated`, in the same transaction. A check that no longer holds under the
  transaction's locks (the holder, its ids of the type, the archive row, another record
  registering the id) decides again from what changed. A read or write that fails withholds
  the updates carrying the id until the next sync run, rather than leaving the usual
  resolution to place them.
- **Re-issue.** Otherwise the update is written as a new record, and a `source_id_reissued`
  decision names both records and opens a review task once the write lands. The new record
  never joins the old one automatically. When a record already carries the uid the id derives,
  live or merged away, the new record gets a fresh uid, derived from that uid and the archived
  rows so a retried batch picks the same one; writing to the derived uid would land the update
  on the old record. The usual resolution may still attach the update to a record with no
  history of the type, such as a discovered record of the same device, but never to a record
  that held the id.

The archive never merges two live records. This pins the model's `FreshIds = FALSE` case: a
source that re-issues an old id to a different asset produces a review task, not a false merge.

The remediation rollback (D11) moves archived rows back to their holders under the same locks
and checks, and records `source_id_reactivated`. It does not restore a tombstone: the rollback
restores the records it deleted itself.

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
That is address-as-identity, which D1 of the strong-identity goal forbids. The tombstone keeps
the uid the address derives, and no sweep restores a `seed_released` tombstone, so while it
remains a sweep of the address seeds nothing: the create is a duplicate and is skipped, as it
was for the live shell. Once the purge removes the tombstone, a sweep seeds the address again
through the normal discovery path.

### D9. Blocked components carry an evidence fingerprint

`DuplicateSweep` computes an evidence fingerprint (`BlockFingerprint`) for each component it
blocks as an ambiguous transitive component, and for each pair it attempts that a merge guard
refuses: the asserted-distinct, agent and source-authority guards, and the provisional-identity
guard with its distinct-MAC check. The fingerprint covers every input those decisions read:

- the reconciliation rule version, a constant changed with every change to the merge rules;
- the sorted device set and, when the outcome depends on the merge direction, the survivor.
  Only the provisional-identity guard reads the direction, so the survivor is part of the
  fingerprint only when one of the devices is a provisional topology sighting;
- the evidence that joined the component;
- each device's live and archived identifier rows of the merge identifier types (type, value,
  partition and the source id their metadata names);
- each device's tombstone state, agent id, identity state and identity source;
- each device's registered interface MACs;
- the distinct assertions within the set.

That is more than the identifiers, because the guards read more than the identifiers. An input
left out could change the outcome without changing the fingerprint, and the component would stay
blocked on evidence that no longer holds.

The fingerprint is stored in the evidence of the identity decision the block records (the
`component_block`, `guard_block` or `source_block` decision for that set). On the next run, a
component or pair whose current fingerprint equals the one recorded is skipped. It is neither
re-attempted nor re-recorded, so the decision's occurrence count measures evidence changes
rather than runs.

The fingerprint changes whenever its inputs do:

- a retirement (D1) changes the archive state, so a pair blocked by a since-retired id is
  re-evaluated and can succeed;
- a deploy that changes the rules changes the rule version, so everything is re-checked once.

A recorded fingerprint is trusted only for a bounded time after its decision was last made
(24 hours by default). After that the component is evaluated again whether or not it changed,
which bounds the cost of an input the fingerprint misses or of a change between the read and
the attempt. The merge cooldown depends on time rather than evidence, so its blocks carry no
fingerprint and are attempted every run. A source-authority conflict found only under the merge
transaction's locks is recorded without a fingerprint, so the next run attempts the pair again.
A failed read of the fingerprint inputs leaves the components unfingerprinted, so they are
attempted as if new.

Blocked merges are reported as blocked, never as errors. A skipped pair is counted as a blocked
merge and as blocked and unchanged; only a merge counts toward the merge cap. The run record
gains:

- `blocked_merges`: the merges a guard refused, which the run used to count as errors;
- `blocked_unchanged`: the blocked components and pairs skipped as unchanged;
- `succession_merges`, `succession_reviews`, `successions_skipped` and `successions_deferred`:
  the succession pass's counters (D3, D4), which the run only logged;
- `max_successions_configured`: the per-run succession cap the run was given, or nil when it
  had no succession candidate and so read none.

### D10. The formal model

These changes go in `formal/dire`. They are specified here as tasks and land before any code
(tasks 1.x).

**Resolution model (`DireResolution.tla`).**

- `srcOf` becomes a variable, initialized from the constant `SrcOf0`.
- `Rekey(h, a)` gives a device a new id. It is gated by the constant `Rekeys`, so every
  existing environment keeps its state space. Under the constant `FreshIds`, a re-key uses an
  id never issued before.
- A ghost `recFs` records, per record, the source first-seen times it carries, each naming the
  physical device whose hostname and MACs come with it. Two devices never share a first-seen
  time. A new constant, `HostOf`, gives each device its hostname, so cloned machines can share
  one. Another, `NewFirstSeenIds`, names the ids under which the source reports a device with a
  new first-seen time, so a re-key can change it; under any other id the source reports the
  device's original one.
- A ghost `seenWith` records, per record, the source ids already issued when the source last
  saw its device. It stands for D3's time guard: a hostname corroborates only when none of the
  successor's ids is among them. A re-key to an id, new or re-issued, removes that id from every
  record's set, because the source first sees it after every record's last sighting.
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
- `AliasFollowsSyncedDevice`, an action property: after a source sync observes a device at an
  address, every identified record keeping a confirmed alias of the address describes that
  device. The traces found it broken today (see "The revision the traces made").

**Defect switches for today's code.** Each goes in `KnownBugs` and `CurrentBugs.ResolutionBugs`
only after its counterexample is confirmed against the Elixir code, as "Known DIRE Defects Have
Witness Configurations" requires.

| Switch | Witness | Expected |
| --- | --- | --- |
| `retired_source_id_vetoes` | `resolution_witness_retired_source_id_vetoes` (environment `armis_rekey`) | `violation:OneSourceRecordPerDevice` |
| `stale_holder_keeps_address` | `resolution_witness_stale_holder_keeps_address` | `violation:ObservedAddressHeld` |
| `released_seed_stays_live` | `resolution_witness_released_seed_stays_live` | `violation:NoAddresslessShell` |
| `armis_alias_pass_blind` | `resolution_witness_armis_alias_pass_blind` | `violation:AliasFollowsSyncedDevice` |
| `foreign_sighting_confirms_alias` | `resolution_witness_foreign_sighting_confirms_alias` | `violation:AliasFollowsSyncedDevice` |

The traces found the last two, and D16 fixes them.

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
| `overlapping_hostname_corroborates` (a hostname corroborates without D3's time guard) | `resolution_unsafe_overlapping_hostname_corroborates`, environment `armis_clones` | `violation:NoFalseMerge` |

**New environments and configurations.**

- Environments:
  - `armis_rekey`: one device, observers Armis and Sweep, re-keys on.
  - `armis_rekey_shared_mac`: two devices sharing a MAC, re-keys on.
  - `armis_reissued_ids`: `FreshIds = FALSE`.
  - `armis_clones`: two devices cloned from one image, sharing a MAC and a hostname; either may
    leave the source.
  - `armis_rekey_new_first_seen`: `armis_rekey`, except that the source reports the device with
    a new first-seen time under its new id, so only the guarded hostname corroborates the pair.
- Each environment gets a `resolution_goal_*` configuration that checks every existing goal
  property plus the new ones.
- `resolution_vacuity_succession` expects `violation:NeverSucceeds`, proving that the goal does
  merge a re-keyed pair.
- `resolution_vacuity_hostname_succession` expects `violation:NeverSucceeds` in
  `armis_rekey_new_first_seen`, proving that the guarded hostname alone does merge a re-keyed
  pair.

**Lifecycle model (`DireLifecycle.tla`).**

- `Expire` is gated by a new constant, `ExpiryEnabled`.
- `Reasons` gains `expired`, `source_retired` and `seed_released`, so `Expire` no longer records
  the generic `other`.
- Each record carries a sweep-only discovery flag. A new `SweepCreate` sets it, for the seed a
  sweep creates at an address no row holds; any other source's write, a merge with a record
  that has another source, and an agent check-in clear it.
- The sweep action, `Sweep(p, d)`, matches the live holder of the address, or else a
  tombstone, and follows the code's rule: it restores (`SweepRestore`) a tombstone that has a
  non-sweep discovery source, or (once D12 lands) an `expired` one. Otherwise it writes the
  sighting (`SweepRefresh`): to a live record, and today to an unrestored tombstone as well.
  Once D12 lands, an unrestored tombstone is left alone (`SweepSkip`).
- New actions, gated by a new constant, `RetirementEnabled`:
  - `Retire(u, R)` archives the ids `R` (D1), none of them a MAC, and marks the record when
    `R` is every other id it holds (D5), so it is also the design's `MarkRetired`. A constant,
    `MacIds`, says which identifiers are MACs;
  - `GraceDelete`;
  - an evidence sighting of a `source_retired` or `seed_released` tombstone, a `CommitWork`
    branch that drops the write;
  - reactivation, a `CommitWork` that reports a retired id of the record or of a record merged
    into it (D6).
- Properties:
  - `RetiredTombstoneStaysDeleted`: no evidence path restores a `source_retired` tombstone.
  - `MarkedHoldsOnlyMacs`: a marked record is live and holds no identifier but a MAC.
  - `SweepWritesOnlyLiveRecords`, an action property: a sweep write changes only a record that
    is live after the step.
  - `ExpiredDeviceReturns`, an action property: a sweep that matches an `expired` tombstone
    restores it.
  - `lifecycle_goal_no_expiry` sets `ExpiryEnabled = FALSE` and must pass, so the goal does not
    rest on expiry silently.
  - `lifecycle_vacuity_grace_delete` expects `violation:NeverGraceDeletes`.
  - `lifecycle_vacuity_reactivate` expects `violation:NeverReactivatesRetired`.
  - `lifecycle_vacuity_expired_returns` expects `violation:NeverRestoresExpired`, proving that
    the goal does restore an expired sweep-only tombstone.
  - Retirement is checked by two goal configurations of its own, `lifecycle_goal_retirement`
    (two devices, two identifiers) and `lifecycle_goal_retirement_chain` (a three-device merge
    chain, one identifier). The three-device goal and `lifecycle_goal_no_expiry` keep
    `RetirementEnabled = FALSE`, so each check stays inside its budget.
- Defect switches, under the same confirmation rule as the resolution switches. The second was
  confirmed by task 9.7 (D12):

  | Switch | Witness | Expected |
  | --- | --- | --- |
  | `sweep_refreshes_expired_tombstone` | `lifecycle_witness_sweep_refreshes_expired_tombstone` | `violation:ExpiredDeviceReturns` |
  | `sweep_recreates_purged_seed` | `lifecycle_witness_sweep_recreates_purged_seed` | `violation:NoPurgedResurrection` |

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
(`assert_golden!(demonstrates: ...)`), unless the switch only withholds an action (see "The
revision the traces made" below). The fix pull request regenerates it.

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

**The revision the clone environment made.** A scratch run of two clones sharing a MAC and a
hostname found a fourth counterexample to `NoFalseMerge`. One clone left the source and its id
retired. The shared hostname then corroborated its record with the other clone's, and the
reconciler merged two devices. D3 now guards the hostname with the first-seen and last-seen
times. The unguarded rule is the rejected alternative `overlapping_hostname_corroborates`, and
`armis_clones` checks the guarded rule as a goal environment. The guard must not cost a true
re-key its merge: when a re-key changes the first-seen time, only the hostname corroborates the
pair. `armis_rekey_new_first_seen` checks that such a device still converges, and
`resolution_vacuity_hostname_succession` that the merge happens.

**The revision the lifecycle model made.** Writing the lifecycle model exposed one gap in D5,
confirmed by knocking the fix back out: a marked predecessor that survived a
`source_succession` merge kept its mark, so the grace delete would have deleted the record that
now held the device's current id. With the mark cleared only by reactivation, both a merge into
a marked record and an ingest that registers an identifier on one violate
`MarkedHoldsNoIdentifier`, since renamed `MarkedHoldsOnlyMacs` (below). D5 now clears the mark
whenever the record gains a source or agent id, and D3 says so for the merge. Knocking out the evidence branch instead makes `Commit` revive a
`source_retired` tombstone, which `RetiredTombstoneStaysDeleted` reports.

**The revision the traces made.** A knockout checks a trace with its switch turned off and
requires TLC to reject it. `retired_source_id_vetoes` only withholds `RetireAbsent`: with it off,
the model allows every step it allowed before, and more, so it can reject no trace recorded
from today's code. `src_rekey_succession` demonstrates that switch with a trace witness
configuration instead, written by `assert_golden!(witness: ...)`:

- the same trace, checked with today's switches;
- `OneSourceRecordPerDevice` in place of `TraceIncomplete`;
- expecting `violation:OneSourceRecordPerDevice`.

The recorded trace reaches a state in which the re-keyed device's old record still holds its
stale id beside the record for the new id, and neither retirement nor the reconciler would
change anything. The extended `src_attach_shared_mac` keeps two records for two devices today,
which violates nothing, so it has neither configuration and is the fix's regression trace.
The other switches withhold no action and keep knockouts: `armis_moves_onto_sweep_seed` for
`released_seed_stays_live`, and both `expired_sweep_only_returns` and `sweep_restores_merged`
for `sweep_refreshes_expired_tombstone`. The fix deletes a trace witness configuration with the
switch, as it does a knockout.

Recording the traces from today's code also found two defects in the alias pass that the model
did not express. Each was confirmed against the code and added as a switch with a witness:

- `armis_alias_pass_blind`. A source sync's alias pass (`Sync.Aliases.process_alias_conflicts/2`)
  looks for the address's alias under the partition the update's identifiers are filed in, the
  source's own, while `AliasEvents` files the alias under the device's partition. The pass never
  finds it, so an identified record keeps a confirmed alias of an address at which the source
  has since synced another device. `armis_dhcp` records it, and its knockout demonstrates it.
- `foreign_sighting_confirms_alias`. `AliasEvents` looks an alias row up by its address alone
  (`DeviceAliasState.lookup_by_value/3`) and records a sighting on the first row it finds,
  whichever device that row names. In `src_rekey_succession` the new id's syncs confirm the
  address as an alias of the old id's record, and the trace's knockout demonstrates it.

Every goal configuration checks `AliasFollowsSyncedDevice`, which a model that keeps neither
defect satisfies. D16 fixes both, and the fix found three consequences of per-device rows that
neither switch named; two new traces record them.

**The revision the lifecycle trace made.** Recording the `source_retired_returns` trace from the
code (task 12.1) found the lifecycle model out of step with D5 and with the code it drives:

- **MACs.** The model gave every identifier one kind, so `Retire` marked a record only once every
  identifier it held had retired, a MAC included. D5 counts only source and agent ids: a record
  whose source ids retire is marked while it still holds its hardware MAC. The model now types
  MACs (`MacIds`). `Retire` never archives one, and it marks the record when `R` is every other
  id the record holds. A MAC that a write, a merge or an unmerge registers on a marked record
  leaves the mark, as the clearing trigger does. `MarkedHoldsNoIdentifier` became
  `MarkedHoldsOnlyMacs`.
- **Revisions.** Retiring an id bumps the record's identity revision
  (`SourceRetirement.archive/4`). So does a reactivation, whether the record it returns to is
  live or a tombstone (`SourceReactivation`). The model bumped neither a retirement nor a live
  reactivation.

The trace checks the first point and the retirement bump: under either old rule, TLC cannot take
the trace's `Retire` step. The trace reactivates a tombstone, so the live-reactivation bump is
checked only by the code's tests.

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

**A sweep re-creates a purged merged-away seed (task 9.7).** A sweep names a seed by its address
(`create_available_unknown_device/3`). Once a merged-away seed's tombstone is purged, the next
sweep of that address finds no row there and derives the seed's uid again, so it writes the
merged-away uid live, outside the redirect #4620 follows: a source still carrying the uid lands
on the new seed instead of the survivor. The lifecycle trace `purged_seed_sweep` records it on
the real code, and the switch `sweep_recreates_purged_seed` names it. The change:

- **A sweep never seeds under a uid that redirects.** Before it seeds a batch, the sweep reads
  the merge rows of the uids it is about to create in one query. A uid with none is seeded as
  today. A uid with one is resolved (`Resolver.resolve_canonical_device_id/2`): if it resolves
  to itself, an unmerge reversed the merge and the uid is seeded; if it redirects, the seed takes
  the next uid of a chain `Ids.reseeded_device_id/1` derives from it, and that uid is checked the
  same way.
- **The chain is bounded and fails closed.** A host whose chain finds no free uid within the
  bound, or whose uid cannot be resolved, is not seeded and is logged; a failed read of the merge
  rows seeds none of the batch, since an unanswered lookup is never read as "no merge".
- The chain is deterministic, so every sweep of the address derives the same uid. One side
  effect: a merged tombstone that no longer holds the address its uid derives from used to keep
  the sweep from seeding there until the purge, since the create was skipped as a duplicate; the
  seed now takes the next uid of the chain.

Rejected: never seeding the address of a merged-away uid, which would hide a live host from
inventory for good; and dropping the merge row with the purge, which is the redirect #4620
relies on.

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

The order puts the changes that shrink the visible inventory first, so the default device count
drops as early as possible:

1. Formal model and traces (D10), as a model-only pull request that records today's defects.
2. Schema, settings, retirement and the veto split (D1, D2), including the archive-aware guard.
3. The retired mark, the hidden reads and counts, and reactivation (D5, D6), with the grace
   delete enabled.
4. Released seeds and address claims (D7, D8).
5. Succession and review (D3, D4).
6. Blocked-component accounting (D9), the guardrails and the reserved keys.
7. Sweep restore of expired devices and the expiry hold and counters (D12-D14). These do not
   depend on 2-6 and may land in any order with them.
8. Remediation, the runbook and the end-to-end test (D11), run by an operator after 2-7 are
   deployed.

The alias fixes (D16) land as a pull request of their own between steps 4 and 5. The traces of
step 1 found the defects, and no other step depends on them.

Each fix pull request removes its switch, promotes its property and regenerates its traces, as
"Fixing a Modeled Defect Promotes Its Invariant" requires.

Shipping the grace delete before succession has a cost: a predecessor whose grace period ends
before step 5 is deployed is soft-deleted as `source_retired` instead of being merged with its
successor. That is reversible. `Device :restore` brings the record back, its archive rows are
kept, and the next succession pass then treats it as a predecessor.

### D16. An alias row belongs to one device

`device_alias_states` is unique on device, type and value (`unique_device_alias`), so an address
can carry a row for every device seen at it. The model gives each device its own row and handles
every holder of an address. The code did neither, which the traces recorded as
`foreign_sighting_confirms_alias` and `armis_alias_pass_blind` (D10). This decision brings the
code to the model:

- **A sighting counts toward the sighted device's own row.** `AliasEvents` looks a row up by
  device and value (`DeviceAliasState.lookup_for_device/4`). A device seen at an address another
  device holds a row of gets a row of its own, and the confirmation threshold counts one
  device's sightings. Another device's row at the address is never touched.
- **The sync's alias pass reads the device's partition.** `Sync.Aliases` looks an address's
  aliases up under the partition `AliasEvents` records them under
  (`AliasEvents.alias_partition/2`), not the source's, where the sync's identifiers are filed.

Fixing the two found three consequences of per-device rows that neither switch named. Each lands
with them:

- **Every other holder is handled.** `Sync.Aliases` and `AliasGuard` read one holder of the
  address and acted on it, so a second identified holder kept its confirmed alias. `AliasGuard`
  could also read the resolved device's own row first, skip it, and handle no one. Both now read
  every confirmed holder but the device itself (`Resolver.lookup_alias_device_ids/4`, `except:`)
  and handle each by the rules they already had: an identified holder has its alias invalidated
  and the decision recorded; an address-only holder is merged by the sync pass (#4609) and left
  alone by `AliasGuard` (#4610). Trace `armis_dhcp_two_holders` records the sync pass with two
  holders, and `mapper_prior_alias_holder` records `AliasGuard` reading the device's own row
  first.
- **Every reader takes an address's holders in one order.** The readers that pick one holder
  (the sweep's `DeviceLookup`, `Sync.Lookups`, `Resolver.lookup_alias_device_id/4` and the SNMP
  credential resolver) read the rows in no defined order, and the mapper ranked them its own way.
  They now share `DeviceAliasState.holder_sort/0`: the most recently seen first, then the most
  sightings, then the lowest device id, which makes the order total. Recency comes first because
  an address follows the device most recently seen at it. The mapper still ranks by state first,
  and within a state follows the same order. The fallback to a pending alias keeps the row with
  the most sightings, the closest to confirmation, first, and breaks a tie by first-seen time,
  then by device id. Like the confirmed read, it leaves out an `except:` device.
- **A merge folds a colliding row.** `Reassignments.reassign_alias_states/3` moved every row of
  the merged record onto the survivor in one update. When both held a row of one value, the move
  broke the unique key and rolled the whole merge back. The merged record's row now stays with
  it, `replaced` by the survivor's, and a confirmation it carried confirms the survivor's
  detected or stale row. Every other row moves.

Rejected: one row per address, re-pointed to the device seen last. It keeps the defect's shape:
the row would carry one device's sightings toward another device's confirmation, and a merge or
an unmerge could not tell whose sightings a row holds.

Effects:

- More addresses carry several confirmed holders, where one row used to stand for all of them.
  The NetFlow exporter cache (`NetflowExporterCacheRefreshWorker`) leaves an address with more
  than one confirmed holder unattributed, so it attributes fewer sampler addresses. That is the
  side it is built to fail on: the one row could name the wrong device.
- The sweep's fallback to a pending alias (`DeviceLookup.lookup_detected_aliases_by_ip`,
  `confirm_from_sweep`) now chooses among the pending rows of several devices, in the fallback's
  order.
- When the survivor's row of the value is already `replaced` or `archived`, a confirmation the
  merged record's row carried is lost: the survivor's row is not confirmed again.

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
- **Identifier partitions.** A source's identifiers, its MACs included, are filed under the
  source's partition (`Ids.identifier_partition/2`), and its device rows under the update's.
  `DuplicateSweep` pairs a device's MAC column only with a MAC filed under the device's own
  partition, and the unique identifier index keeps any value from having two holders in one
  partition. Its duplicate pass therefore never pairs two of a source's records today, and
  D2's `identifier_backfill` refusal is not reached for them. D3's succession pass has to find
  the shared MAC under the source's partition, not through the duplicate pass. The models have
  one partition (`formal/dire/README.md`); whether to model partitions is open.
- **Hostname agreement at ingest.** When a source sync's record agrees by hostname with the
  address's holder and adoption is refused, the resolver writes the record as its own device and
  records a `policy_block` decision (`hostname_agreement_not_identity`), which opens a
  de-duplication task. It emits no telemetry beside it, which `DecisionLog` expects of every
  caller. A re-key at the same address therefore opens a task today, before D3 or D4 decide
  anything. Resolved in PR 5: D3's merge marks the open task for exactly the merged pair merged
  into the survivor (`Deduplication.resolve_merged_pair/3`). D4's `succession_review` does not
  replace the decision. A review of the same pair updates the same task, which is keyed by its
  device set. The telemetry landed with PR 2
  (`[:serviceradar, :identity_reconciler, :hostname_agreement, :refused]`).
