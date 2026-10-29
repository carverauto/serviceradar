# One source scan with compact, shared cohort evidence

Status: disabled implementation approved by the product owner on 2026-10-29.
The implementation is prepared for review and changes no production runtime behavior.

## Evidence and limits

The corrected run used synthetic data: 200 devices, 500,000 active facts,
10,200 resolved assessments and about 53,000 dimension proofs. Source
`59385424a42dfde36bbf309d7bc7e982a8bd494d` passed its implemented controls
and cleanup but failed the fact screen. The full measured report remains in
[the preceding proposal](../refactor-exposure-reconciliation-audit/prototype.md#completed-post-correction-verification)
and [portable report](https://agentboard.farm01.carverauto.dev/documents/226).
The [hosted invocation](https://carverauto.buildbuddy.io/invocation/bba2e1ab-20d8-47be-a620-5cf2c775db70)
is the measurement provenance. These are rounded synthetic measurements, not
live fleet figures.

| Evidence | Observed result | Interpretation |
| --- | --- | --- |
| Whole audit | About 31 s | Not the fleet result |
| Fact interval union | About 12 s; screen 6 s | Capacity miss |
| Orchestration interval | About 4.4 s; screen 0.9 s | Above budget; assertion was not reached after the fact failure |
| Source work across two workers | About 22 s inclusive | Overlapping work, not elapsed audit time |
| One 32-device source plan | About 3.7 s; 510,200 assessments scanned for 81,632 selected rows | Broad physical read at this fixture selectivity |
| Source temporary writes | About 8,000 blocks | Wide validated rows and digest materialization spill |
| Coverage plan for the same cohort | About 0.86 s; another 510,200-row assessment scan | Separate source read and JSON reference extraction |
| Coverage lookup work | About 163,000 reference occurrences; 82,000 dimension index executions | Memoization already removes some repeated lookups; not all |

The source plan's joined projection, including replay validation, takes about
2.6 seconds; its input join about 0.4 seconds. Those are inclusive node times.
They do not isolate regex, timestamp, JSON extraction, hashing or I/O CPU.
No pure-validator speedup is claimed. The corrected run was warm and shared;
it establishes neither p95 nor fleet-scale plan selection.

## Production path and existing bounds

The daily reconciliation worker owns comparisons and existing repair
obligations. Production `ExposureReconciliationComparison.assessments/5`
pages current assessments and retained publications, decodes both, and checks
their independent digests. The disabled audit replaces that expensive path
only inside the manual harness.

The source sequence trigger in migration
`20261025185606_retain_exposure_publications.exs` retains the after-image
alongside the new sequence. Ordinary unchanged updates retain the old
publication. Repair regenerates under the existing fact-key lock with a new
sequence. This proposal does not add another writer or change these rules.

A non-partial unique index already begins with
`(device_uid, package_identity_key, cve_id)`, established by migration
`20260902235447_stabilize_endpoint_vulnerability_assessment_identity.exs`.
Adding another device index by assumption is unwarranted. The observed planner
chose a sequential scan at 32 of 200 devices. That does not prove it will do so
at 32 of 20,000 devices, or that forcing an index improves this small fixture.

If a future fleet plan scanned every assessment for each cohort, work would
grow as cohort count times total assessment count. Acceptance must rule out
that amplification at selective scopes. Logical WHERE filtering alone does
not establish bounded physical work.

## Decision 1: one ephemeral source pipeline in the existing view

Use the same locked cohort, finite repeatable-read view V and reader connection
for source facts, required references and proof coverage. Resolve the admitted
ordinals to source UIDs once. The main statement has these logical stages:

1. Select the cohort's assessments once, including resolved rows needed for
   reference coverage. Preserve the existing distinction between eligible
   live-device facts and references needed by lifecycle/terminal scopes.
2. Apply the existing full publication validator once per eligible assessment.
   Normalize retained scalar values only behind its successful validity guard.
   Project current values independently from assessment columns, lifecycle
   ordinals and the current package-version dictionary.
3. Retain a narrow materialized relation: device ordinal, bounded source row
   identifier, validity/drift flags, one current v1 hash, and the required CVE
   and package-version reference ordinals. Raw replay JSON, wide assessment
   fields and timestamp strings do not survive into that shared relation.
   Any intermediary needed to prevent duplicate validation contains only
   current/replay typed scalars and validity, not the original payload.
4. Aggregate fact count and modular sums from every eligible row. Separately
   derive device/reference membership from the narrow relation and the
   cohort's deletion watermarks.
5. Resolve the distinct keys and reduce their eligibility back to each device.
   Return explicit results for every admitted ordinal, including empty scopes.

This is statement-local computation. No new durable source projection,
materialized view, trigger, cache, generated assessment column or backfill is
introduced. No second query rereads the same assessments for ordinary coverage.
A bounded mismatch-localization query remains allowed after failure.

The implementation must show that the physical plan actually shares the source
read and does not inline the expensive validator into both consumers. Naming a
CTE does not prove evaluation count. A compact projection is an execution
hypothesis until its widths, temporary blocks and plan are measured.

## Decision 2: share lookup work, preserve per-device authority

Build distinct `(kind, ordinal)` keys across the cohort. Join each key to its
dimension-state row and the exact current-run proof once. Bind to source
sequence, source content hash and recovery fence exactly as the approved audit
already requires. Attach that result to the device/reference membership.

Only reference membership may be deduplicated. Fact rows retain their original
multiplicity before aggregation. A duplicated active fact must still change
count and digest sums.

Evaluate the covering generation once per device. A shared proof can be valid
for one device and too old for another. Preserve that distinction and record
the minimum evidence time used by each device. No cohort-wide ready flag or
global minimum may replace these per-device predicates.

Include references from resolved assessments, old package versions and deletion
watermarks. Invalid or missing reference material makes the affected scope
unverifiable; do not filter it away, substitute the current version, or treat
it as zero references. Compacted or unprepared terminal inputs follow existing
preparation/recovery authority; this change grants no new success shortcut.

The membership and distinct-key relations exist only within V. They may spill
under ordinary database limits; no fleet-sized persisted edge table or
unbounded client list is allowed. If a skewed device cannot finish within the
existing view deadline, defer it visibly. No partial digest becomes success.

## Decision 3: preserve the validation and recovery contracts

The existing SQL validator and `ExposureTransitions.decode/1` remain the
differential pair. Do not tune the codec, relax timestamp/type/range checks,
replace it with JSON text equality, or cache its result across source views.
Current attributes must still disagree when retained replay and warehouse
agree but current state drifts.

Keep `exposure-fact/v1`, field order, SHA-256, signed-zero handling, NULL
semantics, typed normalization and modular sums unchanged. Hash each eligible
current fact once. StarRocks still hashes actual stored columns independently.
Valid inactive/inactive pairs retain their existing zero-contribution meaning.

Keep two workers, at most 32 devices per cohort, 500-row pages/evidence,
30-second statements and 60-second views. Keep sorted device locks through
comparison publication, source visibility rules, recovery-fence rechecks,
fresh readiness and existing durable repair ownership. A proof arriving after
V requires a fresh bounded view. Changed repair content gets a new sequence
and travels through JetStream; snapshot markers remain intact.

Failure remains per-device where its cause is safely attributable. A statement
or view timeout invalidates its entire unfinished cohort, not an arbitrary
partial subset. Continue other admitted scopes without losing failed work.

## Alternatives considered

| Alternative | Disposition |
| --- | --- |
| Add another device index or force an index/JIT/session plan setting | Existing leading index is present. Inspect selectivity and physical reads first; no tuning settings or new index in this proposal |
| Persist prevalidated retained publications | Could amortize validation, but adds write cost, stale-binding and restore rules, format migration, storage and backfill. Current evidence does not isolate enough of that benefit to justify the new trust boundary |
| Only narrow the existing CTEs | Reduces copying but retains the second assessment scan and repeated coverage extraction; include narrowing in the shared pipeline |
| Raise worker or cohort limits | Changes contention and hides work amplification; excluded |
| USP-01 orchestration | Does not by itself remove these SQL scans, projections or spills; any integration needs its own measured path |

The selected design reduces identifiable repeated work while leaving the
authoritative sources and publication path intact. It is not a promise of a
twofold speedup. Validation can remain the dominant cost.

## Acceptance, accounting and stop rules

Implementation approval permits a disabled prototype and review. It does not
allocate hosted capacity. A subsequent request must name the exact commit,
run count, existing capacity profile, synthetic sizes, concurrency, cleanup
owner and expected stop points.

A future bounded measurement must collect:

- Actual source/coverage plan, eligible/visited row counts, validation
  evaluation evidence, intermediate widths, temporary blocks, distinct keys,
  reference occurrences and physical dimension lookup executions.
- Selectivity evidence: fixed cohort work with added unrelated synthetic
  devices. The main source read must not grow with unrelated rows as one full
  scan per cohort. A small-fixture sequential scan alone is not a fleet verdict.
- Shared-key and mostly-unique-key cases, including skew and terminal-only
  references. A speedup on repeated keys must not conceal worst-case work.
- Complete audit timing, resource use, setup separately, all existing controls
  and verified cleanup. Inclusive worker times are not added as elapsed time.

Charge the entire fused source-and-coverage statement to the existing
6-second small-profile fact screen. Keep the residual orchestration screen
at 0.9 seconds. This conservative accounting cannot create a pass by moving
coverage out of the orchestration timer. Continue reporting the combined
linear interval and all other orchestration/readiness work. Keep dimension,
retry and fleet budgets unchanged.

Acceptance requires the implemented correctness controls and physical sharing
evidence to pass. If either component screen fails, stop; report the result.
No automatic rerun, codec sweep, broader cohort, higher concurrency, cache
fallback or fleet attempt follows. Even a passing screen only supports a
separate fleet-run request. The 20,000-host / 50-million-active-fact / 900-second
gate remains open.

## Required regression controls

Use the existing decoder/digest parity suite and owning audit harness. Add
only missing controls after the repository's test-audit review:

- Shared dimensions with different covering generations: one device can pass
  while another is deferred; preserve each oldest evidence time.
- Duplicate facts versus duplicate references: only reference lookup work is
  deduplicated; count and sum still detect extra facts.
- A malformed publication/reference and a terminal-only old version: preserve
  failures and required coverage.
- Current-only drift, same-count warehouse corruption, warehouse-only keys and
  explicit empty devices: unchanged truth conditions.
- Proof arriving after V, equal-sequence dimension content edit, expiry,
  timeout, recovery-fence change and interrupted result publication: no stale
  or partial success.
- Live transitions before and after snapshot completion, including visible
  sequence 40 followed by resolution at 41: existing ordering still wins.

Previously unexecuted process-death/live-finalization controls remain open;
a query refactor cannot close them by inheriting a green unit result.

## Migration, rollback and approval

There is no production migration or data rewrite. The disabled harness continues
to own scratch metadata and cleanup. Rollback selects the preceding manual
implementation; no persistent source state needs reconciliation.

Approval recorded: the product owner answered "approved continue" on
2026-10-29, authorizing this shared, compact source pipeline only in the
disabled harness and its normal remote validation through no-mistakes.
Hosted allocations, production integration,
new persistent validation data and rollout require separate decisions.

## Implementation checkpoint

The manual harness now uses one statement for fact summaries and dimension
coverage. A guarded lateral projection computes publication validity before
materializing typed values; a second compact relation carries fact hashes,
drift flags and reference ordinals. No raw replay JSON is retained in either
shared materialization. Per-device fact aggregation preserves every row.
Distinct reference memberships resolve cohort dimension keys before applying
each device's covering-generation floor and evidence time.

Malformed reference ordinals become missing coverage rather than unsafe casts
or omitted dependencies. The existing audit controls exercise duplicate
source contributions, malformed assessment and terminal references, a
terminal-only dependency, and distinct device generation/evidence ages.
Those implemented controls passed in the single hosted run below.
Process-death and live-finalization controls remain open.

The full fused statement is charged to the fact interval. Output separates
assessment rows, reference occurrences, device/key memberships and cohort
dimension keys. Existing thresholds, publication and readiness fences,
decoder/normalization functions and v1 digest encoding are unchanged.

## One authorized measurement

Commit `768bb8cebc1edcab762624c130c410eb9e6654ec` was tree-verified remotely
and executed once on the existing small synthetic profile: 200 devices,
500,000 active facts and 10,200 resolved assessments. All 200 devices matched.
Decoder and digest parity passed. The implemented owning-harness controls
passed, including duplicate source facts, malformed source and reference
values, terminal-watermark-only coverage, distinct generation floors,
unchanged proof age, current-only drift, warehouse-only data, proof-after-view
ordering, recovery fences, expiry and timeout behavior.

Physical sharing was observed for one 32-device diagnostic cohort. The fused
statement read the assessment table once, still scanning about 510,000 rows
to select about 82,000. The validator result executed once per selected row.
Rounded inclusive node time for that per-row work is about 2.2 seconds, and
the complete typed projection took about 3.1 seconds. Those figures are
inclusive plan timings, not a CPU profile. EXPLAIN Plan Width values for
the typed and compact projections were about 180 and 60 bytes. Those values
are planner estimates, not measured row sizes. Raw replay JSON is not carried
through the typed and compact shared materializations.

The fused statement took about 5.1 seconds, compared with about 4.6 seconds
for the preceding separate source and coverage plans combined. Global cohort
key deduplication reduced the cohort to about 53,000 keys. Proof resolution
used about 53,000 key and proof lookups, compared with about 82,000 before.
Per-device memberships still equaled all 163,000 reference occurrences, so
that membership deduplication removed no rows. It spilled into five batches
and was followed by sort and join work. Temporary writes fell to about
5,500 blocks from about 8,000 for the old source statement alone.
Fewer scans and lookups are confirmed. The screen still failed.

| Measurement | This run | Previous corrected run | Gate |
| --- | ---: | ---: | --- |
| Whole audit | about 34 s | about 31 s | fleet gate remains open |
| Fact interval | about 16.5 s, including coverage | about 12 s, excluding coverage | 6 s; assertion failed |
| Remaining orchestration | about 2.0 s, excluding fused coverage | about 4.4 s, including coverage | 0.9 s; assertion not reached |
| Dimensions | about 15.4 s | about 14.6 s | unchanged |
| Inclusive source plus coverage worker time | about 31 s | about 27 s | diagnostic, not wall time |
| Existing production baseline | about 156 s | about 153 s | 900 s small-run cap |

Fact and orchestration use different accounting in the two runs, so those
columns cannot be read as isolated speedups. Whole-audit time and combined
source and coverage work show no improvement. This single execution is not a
p95, cold, repeated, or fleet result. Execution stopped after the fact-screen
failure. No rerun, tuning sweep, codec change, higher concurrency, persistent
validation state, or fleet attempt is authorized. The result is not a
performance waiver.

Scratch warehouse tables were empty before removal. Schemas, temporary
grants, and run-owned CNPG fixture databases were removed. Generation release
passed. No cluster was created or removed. The authorized run used existing
shared infrastructure. Separate checks found zero run-owned databases in both
execution locations. No deployment addresses or raw plans are recorded here.

Task 2.2 stays incomplete. This fixture does not supply fleet selectivity or
a mostly-unique-key case. A small-fixture scan of about 510,000 rows does not
bound work at 32 of 20,000 devices. Parent task 1.6, the fleet gate, and
runtime adoption stay open. On 2026-10-29 the product owner approved
publication of this disabled experiment as a negative result. That approval
is a publication-only Test exception. It does not accept the failed
performance screens, change the gates, or authorize another allocation.

Ordinary unit and assembly checks below are unit validation. They are not
live-product scenarios and do not replace the hosted measurement above. The
first full unit gate passed 486 tests, failed one unrelated camera storage
transport assertion, and skipped two Swift tests. That unchanged camera test passed on
retry. A pre-rebase retry passed 487 tests with the same two Swift skips and
does not cover the rebased head. The exact-head remote unit gate passed 487
tests with two Swift skips. Explicit remote assembly of the manual audit
target passed. Assembly does not execute the SQL. `.bazelrc.remote` is a
physical mode 0600 copy in this checkout. `.bazelrc.local` is absent and was
not copied. Provenance links are in the
[review receipt](../../../docs/architecture/exposure-source-validation.receipt.md).
