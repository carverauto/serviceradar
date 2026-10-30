# Content-bound retained-publication validation

Status: the product owner approved one disabled scratch prototype on
2026-10-29. Ordinary remote validation and no-mistakes publication are in scope.
Manual measurement allocations, production migrations and runtime adoption
remain separate decisions. No new capacity result is claimed.

## Evidence and limits

The one authorized shared-scan measurement on source `768bb8ce` used 200
synthetic devices, 500,000 active facts and 10,200 resolved assessments.
Correctness controls passed; capacity failed. The whole audit took about 34
seconds, fact work including coverage about 16.5 seconds, and residual
orchestration about 2 seconds. The unchanged component screens are 6 and 0.9
seconds respectively; execution stopped at the fact failure.

For one 32-device cohort, the fused source statement took about 5.1 seconds.
Its typed projection took about 3.1 seconds inclusive, including roughly 2.2
seconds in the per-row validator; source reading/joining was about 0.4 seconds.
The validator executed once per selected assessment. This supports investigating
repeated decoding, not another scan-sharing rewrite. It does not prove how much
time caching removes. These are inclusive EXPLAIN timings, not independent CPU
costs. The statement still has current hashing, reference coverage and joins.
Even eliminating validation alone gives no evidence that the 6-second screen
will pass.

The [recorded result](../refactor-exposure-cohort-source-scan/design.md#one-authorized-measurement)
and [hosted invocation](https://carverauto.buildbuddy.io/invocation/b7ddf7ab-a7ad-4b94-95ef-0c8164395730)
are the evidence. There is no new performance result in this proposal.

## Decision 1: reuse a source validation receipt, never a current-fact result

Add a scratch-only stored generated fingerprint to the assessment's retained
`last_exposure_publication`, provisionally SHA-256 of `jsonb_send(payload)`.
The entire payload is bound, including fields outside the active-fact digest.
NULL payloads remain unprepared. This is source-local content identity, not a
wire format or another fact digest.

Use a separate validation control table with at most one row per assessment ID:

| Field | Purpose |
| --- | --- |
| assessment ID | Primary key and cascading foreign key to the assessment |
| payload fingerprint | Exact source content that was examined |
| validator revision | Explicit version of decoder, digest and fingerprint semantics |
| valid after-image | Full existing decoder verdict, not just digest-field validity |
| replay state and replay digest | Existing active `exposure-fact/v1` hash; inactive state retains zero-contribution semantics |
| CVE, package and package-version ordinals | Bounded reference identities needed by the existing comparison and coverage checks |

Store neither raw JSON nor a typed copy of severity, scores, flags or other
fact attributes. This is validation control metadata. It cannot serve exposure
queries or replace the StarRocks fact store. Do not store a current-assessment
hash, warehouse match, ready flag or warehouse evidence time here. Production
adoption would require an Ash resource and measured storage; the prototype
uses only its disposable scratch schema.

The generated fingerprint is recomputed from the actual row after its BEFORE
triggers. The existing sequence trigger retains the old publication on an
ordinary unchanged update and constructs a fresh one for a real transition or
repair. The receipt table avoids updating that source row just to cache a
verdict: receipt persistence must not allocate a sequence, enqueue an outbox
message or invoke a source repair.

PostgreSQL documents stored generated values as write-time, row-local and
immutable-expression-only, and places their computation after BEFORE triggers.
The prototype must verify the exact expression on the supported database
image. Do not declare a lookup or full decoder falsely immutable. See
[PostgreSQL generated columns](https://www.postgresql.org/docs/18/ddl-generated-columns.html).

## Decision 2: bounded preparation with the existing decoder

Read at most 500 assessment publications and their fingerprints per page.
Use `ExposureTransitions.decode/1` to validate the complete after-image and
the existing v1 digest implementation to derive its replay digest. A valid
result must be exactly one fact, not an empty decode or lifecycle event.
Derive reference ordinals with the existing safe reference validation rules.
Keep reference validity independent of full payload validity: tombstoned
assessment scopes still need references, while their ineligible facts retain
the current zero-contribution behavior.

Persist the receipt only if the assessment still has the observed fingerprint.
In a short fresh transaction, lock that source row with a non-waiting shared
lock, recheck the fingerprint, then upsert the receipt. Use the same ordering
for all preparation paths: source row before receipt; never hold a fact-key
advisory lock while waiting for that row. A changed or locked row is deferred.
Deletion cascades the receipt; a key change changes the complete payload's
binding. A paused old preparer cannot overwrite the receipt for newer content.
The cohort independently verifies the binding, even after a successful write.

Preparation uses the existing two-worker budget, 500-row page bound and
30-second statement deadline. It is a prototype helper, not a new production
scheduler. A later adoption must integrate bounded work with existing
preparation ownership. Persist page progress with its work; a poison publication
gets a content-bound invalid verdict and bounded diagnostic identity, rather
than indefinitely blocking the first page. A changed payload becomes eligible
for validation again. Repair remains owned by the existing repair records.

During an audit, a missing or stale receipt schedules bounded preparation and
defers that device. Retry in a fresh view; a receipt committed after view V
cannot appear inside V. Admission has a finite cursor/pass boundary, and misses
behind it remain explicit deferred work. No fleet-sized client cache or
unbounded receipt-version history is allowed.

## Decision 3: keep three independent checks

Within the same locked, finite repeatable-read view V:

1. Require the receipt fingerprint to equal the assessment's generated
   fingerprint, and its revision to equal the active validator revision.
   Require a valid full after-image for eligible fact scopes. Missing or
   malformed reference material remains a coverage failure for reference
   scopes, including tombstoned assessments.
2. Project current values independently from assessment columns, lifecycle
   ordinals and the current package-version dictionary. Preserve all existing
   validity checks. Hash the current active tuple once with the unchanged v1
   encoding, then compare with the bound replay digest. Active/inactive
   disagreement is drift. Two valid inactive rows keep zero-contribution
   semantics. Do not substitute a receipt hash for the current hash.
3. Independently hash actual StarRocks columns and compare count and modular
   sums. Preserve duplicate multiplicity, empty devices and warehouse-only
   rows. Check exact-version dimension proofs with each device's generation
   floor and oldest evidence time before publishing a result.

This replaces repeated full replay validation and replay JSON projection in
the experimental audit; it does not remove validation. Validation was done
against the complete, fingerprint-bound payload. Current-only drift still
fails even when retained replay and warehouse agree.

Watermark-only terminal references keep the existing direct bounded path in
the first candidate. Do not invent receipts for compacted payloads, omit old
package versions, change terminal semantics or let a successful source receipt
stand for a warehouse proof.

## Decision 4: invalidation and recovery

An equal-sequence payload edit changes the generated fingerprint and invalidates
reuse. No sequence-only trust is permitted. A decoder or digest semantic change
requires a new validator revision; old receipts cannot qualify. A PostgreSQL
major/serialization change requires fingerprint recomputation and receipt
invalidation before using the candidate. Validate these mechanics in scratch;
production migration/upgrade behavior remains a separate adoption gate.

A warehouse restore invalidates audit runs and warehouse proofs through the
existing recovery fence. A source validation receipt may survive because it
claims only that these exact source bytes decode to this digest; it makes no
warehouse claim. The new audit must still read actual warehouse rows and
obtain fresh dimension evidence. A CNPG restore also resets audit/warehouse
evidence through the existing recovery entry point. Source receipts qualify
only with matching content and the currently installed revision; unknown
revision or fingerprint compatibility requires cold preparation.

Receipt creation time never refreshes fact or dimension evidence. Existing
run deadlines, generation floors, repair obligations, readiness predicates
and commit-time recovery checks remain authoritative. Normal live traffic
continues. Test changes both before and after snapshot finalization, including
visible sequence 40 followed by resolution at 41; process death cannot publish
partial success.

## Alternatives and cost

| Option | Decision |
| --- | --- |
| Cache only a boolean validation result | Insufficient target: still extracts and normalizes the retained tuple and references every audit |
| Cache the whole typed replay row | Avoids projection but duplicates fact attributes and storage; unnecessary for equality, digest and coverage |
| Cache a current-assessment digest | Reject: can hide current-only drift that reconciliation is meant to find |
| Reuse a receipt keyed only by transition sequence | Reject: equal-sequence payload edits would evade validation |
| Rework the SQL decoder/codec | Excluded by scope; retain the existing differential oracle |
| More workers, capacity or larger cohorts | Excluded; does not remove repeated work |
| Keep current runtime | Remains the default and rollback path; known fleet gate is still unresolved |

This adds a generated fingerprint, one control row per assessment, a bounded
preparation path and an invalidation/version contract. It shifts repeated audit
work into source writes and preparation. Fifty million receipt rows are a
material storage cost, not a small cache. Actual row/index bytes, WAL, write
latency and preparation throughput must be measured before adoption. There is
no assertion that the savings outweigh these costs yet.

## Acceptance and stopping

Prototype approval permits one disabled implementation and normal remote
validation through no-mistakes. It grants zero hosted benchmark allocations.
A later allocation request must bind the exact commit, run count, existing
capacity profile, synthetic sizes, cleanup owner and stopping conditions.

Keep two workers, at most 32 devices per cohort, 500-row pages, 30-second
statements and 60-second source views. Keep the 6-second fact-plus-coverage
screen, 0.9-second residual orchestration screen and 900-second fleet gate.
Do not move preparation or retry costs out of reported end-to-end time to
manufacture a pass.

A future bounded measurement must report separately:

- First-use/cold receipt preparation and the full audit, with all deferred work.
- Prepared steady-state audit and changed-content preparation during live
  traffic; receipt hit/miss/invalid counts and oldest warehouse evidence.
- Baseline versus candidate source insert/update latency and throughput,
  WAL and heap/index bytes; receipt writes must create no extra transitions.
- Physical source/receipt access at fixed selective cohorts with added unrelated
  rows, plus shared-key, mostly-unique-key, skew and terminal-only cases.
- Complete audit elapsed time, inclusive phase timings, storage, connection and
  memory use, followed by canonical and independent scratch cleanup.

Any failed component screen stops the experiment. A cold/recovery miss remains
a miss even if the prepared case passes. Numeric source-write and storage
acceptance limits must be set in the allocation request before execution;
they cannot be selected after seeing results. Do not run a fleet attempt,
tune the codec, repeat the measurement or enable runtime after a failed screen.
Passing this screen supports only a separate fleet-run request. Parent task
1.6, full protocol/live-finalization evidence and fleet capacity stay open.

## Migration and rollback

The initial candidate alters only disposable synthetic databases. It adds no
production migration, source trigger or enabled worker. Remove scratch receipt
state after verification. Before production adoption, separately review and
measure the generated-column rewrite/backfill and lock cost, Ash resources,
bounded preparation admission, receipt permissions, upgrade invalidation and
restore entry points. Existing pending exposure proposals must be reconciled
at adoption so archiving cannot restore a contradictory requirement.

Rollback disables receipt reuse and returns to the existing reconciler while
preserving repair state and permanent markers. Throughput may again miss the
gate; rollback must not report capacity success. Receipt metadata can be
discarded after consumers stop, without deleting source publications.

## Disabled implementation

`bench/exposure_audit_receipts.exs` uses the existing decoder and digest.
The scratch migration adds the generated fingerprint, one cascading receipt
per assessment, and explicit deferred assessment IDs per run. Run metadata
persists an assessment UUID cursor and fixed upper boundary. Page receipt writes,
deferrals and cursor advancement commit together. Deferred IDs deliberately have
no source foreign key: recording a locked row must not wait for a foreign-key
lock. A bounded retry removes IDs whose source has been deleted.

Preparation reads at most 500 rows, decodes with at most two workers before
locking, and conditionally writes after non-waiting shared source locks. It
never takes the fact advisory lock. Cohort misses stay deferred, then request
bounded device preparation before a fresh comparison. Existing recovery is
not invoked merely because a validation receipt is missing.

The audit statement no longer reads retained JSON for assessment facts. It
requires the matching receipt, recomputes the independent current hash, and
retains actual warehouse hashing and the direct terminal-watermark reference
path. Preparation and its retries are included in end-to-end time and added
to the fact component interval before applying the unchanged screen.

The owning manual harness includes new stale-content, revision, paused-preparer,
locked-row, poison-progress, deletion, late-view and side-effect controls.
Authoring these controls is not execution evidence. Live finalization, supported
database expression validation, source-write/storage cost and capacity remain
unverified until separately authorized execution.

## Repository anchors

- `bench/exposure_audit_sql.exs`: full replay validator, typed projection,
  current hash, safe references and existing shared coverage query.
- `bench/exposure_audit_receipts.exs`: bounded scratch preparation and
  content-conditional receipt persistence.
- `inventory/exposure_reconciliation_comparison.ex`: independent current/replay
  digests and source-only drift detection in the production comparison.
- `inventory/exposure_publication_prepare_worker.ex`: existing bounded,
  restartable publication preparation and conservative readiness semantics.
- `priv/repo/migrations/20261025185606_retain_exposure_publications.exs`:
  source sequence/publish triggers and fact-key repair serialization.
- `event_writer/processors/exposure_transitions.ex`: authoritative full decoder.

All anchors are beneath `elixir/serviceradar_core/` (modules under `lib/serviceradar/`).
