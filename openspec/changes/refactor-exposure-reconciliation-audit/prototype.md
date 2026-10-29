# Disabled prototype validation result

Status: the one approved hosted small-profile run completed. Its implemented
correctness controls passed, but the fact-comparison performance screen failed.
Performance experimentation stopped; there was no repeat or fleet attempt.
Production adoption and parent task 1.6 remain open. A later explicit approval
allows the bounded diagnostic follow-up below; it does not turn the historical
failure into a pass.

## Measured result

[Hosted execution](https://carverauto.buildbuddy.io/invocation/2cf93ca5-a39a-4abf-927a-6eb10a68adfc)
validated immutable source commit `0b60e86d4e49bf3456eb0be3d2f68ec249357bb6`
and tree `79d57280ed1f0eace2e53c91d89286f00f05f115`. The product owner
authorized this single allocation after approving the disabled prototype.
The run used the existing canonical fixture lifecycle, one disposable CNPG
lane and restricted, never-used warehouse schemas. No workstation build ran.

The fixture contained 200 synthetic devices and 500,000 active facts, using two
workers and cohorts of at most 32 devices. Durations below are rounded.

| Measurement | Observed | Small-profile screen | Result |
| --- | --- | --- | --- |
| Existing production reconciler | 143 seconds | Baseline only | 200 devices matched; zero verification violations |
| Complete audit prototype | 34 seconds | Component screens below | All 200 devices matched; performance screen failed |
| Dimension verification | 13 seconds | At most 120 seconds | Passed |
| Fact comparison | 13 seconds | At most 6 seconds | Failed |
| Remaining orchestration | 8 seconds | At most 0.9 seconds | Above budget; later assertion not reached |

ExUnit reported one test and one failure: `fact component screen failed; no
fleet attempt`. The first failed assertion stopped measurement before the
orchestration assertion and second repetition. Correctness controls ran after
the measurement failure and reached their final success marker. The reported
fact interval excludes overlap between workers; remaining orchestration is
the residual wall time after dimensions and fact intervals, not a separate
CPU profile.

Decoder/digest parity passed for 11 row cases and two aggregate cases on both
engines. The implemented generated-binding, replay-drift, same-count corruption,
missing-fact, terminal-reference, per-device failure, busy-device, snapshot
generation, readiness, proof visibility/age, timeout, expiry, restore-fence,
durable-resume and metadata-cleanup controls passed. Synthetic concurrent
after-images covered sequences 40, 41 and 42; they are not live JetStream or
snapshot-finalization validation.

The prototype retained about 53,000 proof rows occupying about 10 MiB, and
reported about 163 MiB of VM memory at completion. These are proof storage and
completion memory, not total database footprint or peak RSS. The fixture and
production baseline warmed the databases; this is not a cold measurement. The
roughly fourfold improvement on this fixture does not establish fleet capacity
or predict the unchanged 20,000-host / 50-million-active-fact / 900-second gate.

Cleanup completed despite the test failure. The canonical observer, CNPG
teardown and generation release each returned success. In both eligible
warehouse contexts, all five scratch tables were independently counted empty
before their schema grants were revoked and schemas dropped. Follow-up reads
verified both schema absence and grant absence. Raw operational identifiers and
credential-bearing runtime records remain outside the repository.

The original experiment stopped at this failure. The separately approved
follow-up below supersedes the prohibition on one additional small diagnostic
allocation only. Codec tuning, extra workers, wider cohorts, fleet attempts and
runtime adoption remain forbidden. Independent no-mistakes review and
publication remain outstanding.

## Executable boundary

The only entry point is the manual Bazel target
`//elixir/serviceradar_core:exposure_reconciliation_audit`. It reuses the owning
capacity fixture and accepts only `EXPOSURE_CAPACITY_PROFILE=smoke`: 200 invented
devices, 500,000 active facts, 50,000 CVEs, 2,551 package versions and 51 resolved
facts per device. Both the harness and prototype refuse the fleet profile.

The six `bench/exposure_audit_*.exs` files own SQL comparison, scratch metadata,
read-only Ash resources, grouped readiness, orchestration and controls. No
production module, application domain, scheduler, migration-discovery path or
warehouse grant enables this code. The original manual production capacity
target remains available independently.

A scratch-only Ecto migration adds the generated dimension content hash and
four control tables. Installation requires the explicit prototype flag, a fresh
canonical disposable CNPG clone and no prior prototype tables. Cleanup removes
the migration, fixture rows and owned Oban work, then restores parked bootstrap
jobs and supervised processes. Canonical observer, teardown and generation
release remain mandatory; the outer coordinator drops the warehouse scratch
schema and verifies absence.

## Implemented behavior exercised

- Durable cursor and work admission commit together. Resume reads stored state;
  duplicate resume does not re-admit work. Read-only Ash resources expose the
  control records; batched state transitions use fenced transactions.
- Dimension pages inspect at most 500 rows. Only actual source/warehouse content
  matches earn proofs. Failed versions leave dependent devices deferred while
  unrelated devices retain distinct results. Evidence is bound to run, source
  sequence and generated content hash.
- Two workers compare cohorts of at most 32 devices under the existing advisory
  lock namespace. Session locks span comparison, result commit and readiness;
  busy devices defer. Source views end within 60 seconds with 30-second statement
  limits. Result publication checks the recovery fence, run expiry and newest
  covering completed snapshot.
- A newer covering snapshot invalidates older evidence. One coalesced corrective
  proof pass can refresh stale or newly observed versions outside the cohort's
  source view, followed by a fresh comparison. The prototype conservatively
  refreshes proofs older than any completed snapshot; it does not claim an
  optimized per-reference refresh scheduler. Continuous changes fail the run.
- Current facts use the existing v1 SHA-256/count/modular-sum contract once;
  normalized replay fields and required types are checked independently. Actual
  warehouse columns supply the independent digest. Malformed inputs cannot be
  filtered into an empty match. Timestamp validation follows the decoder's
  Gregorian date, fractional precision and offset rules; the implemented hosted
  differential cases passed.
- Readiness batches preserve the existing reason set, including young outbox
  traffic, old outbox entries, recovery journals, repair obligations and snapshot
  generation floors. Cleanup pages remove expired superseded metadata while
  retaining the active and latest completed proof set and all existing repairs.

## Restore and rebuild integration boundary

| Existing entry point | Prototype behavior | Required before production adoption |
| --- | --- | --- |
| Operator warehouse restore or schema/table rebuild | Harness calls `State.invalidate!/0` before an owned destructive operation | Wire the persisted fence into the authorized operational restore/rebuild path before mutation |
| `ExposureSnapshotWorker.perform/1`, reader recovery and `ExposureSnapshotState.create/4` | Existing snapshot generation records are read; newer completion prevents stale result publication | Integrate audit scheduling with normal and replacement snapshot initiation; verify interruption/restart behavior |
| `ExposureSnapshotFinalizer.recover/1` and reconciliation `recover_snapshot/1` | Existing recovery records stay authoritative and readiness-blocking | Preserve assigned repair ownership while invalidating reusable evidence for warehouse recovery |
| `ExposureDelivery.with_lane/3` and retained delivery recovery | Incomplete journal phases continue to block scoped readiness | Verify live retained-input recovery with the adopted worker; never treat a journal acknowledgement as a dimension proof |
| Audit format or PostgreSQL serialization change | Persisted format version and fence reject obsolete runs | Recompute generated identities and invalidate every prior proof before enablement |
| Rollback | Invalidation rejects old-worker result/proof commits; old production worker remains available | Exercise rollback with unresolved repair obligations on the adopted runtime path |

An unannounced external restore is not detected by magic. No production restore
hook has been installed by this disabled prototype. The mappings above are
integration obligations, not claims that production adoption is complete.

## Controls and claims

The manual target checks decoder/digest parity, generated identity after an
equal-sequence edit, source/replay drift even when warehouse equals current
source, same-count corruption, missing and warehouse-only facts, truthful empty
devices, terminal-only references, missing shared dimensions, per-device lock
contention, fresh readiness, newer snapshots, proof visibility across source
views, expiry, recovery fencing, durable resume and retention cleanup.

Concurrent synthetic after-images exercise sequence 40 in an open source view,
resolution at 41 during that view and publication at 42 after it closes. These
are comparison controls; they do not prove JetStream delivery or snapshot
finalization. The existing live harness owns those claims and remains required
before adoption. No control is reported as passed merely because it is present.

## Approved hosted protocol

The approved allocation used a fresh canonical `serial_2` fixture clone and never-used exposure warehouse
schema on the already-authorized lab warehouse. Use the existing fixture
observer/teardown/release workflow described in
[the live harness runbook](../../../docs/exposure-reconciliation-live-harness.md).
Run the manual audit target explicitly; never enable it for ordinary CI discovery.

The run first verifies the existing production baseline on the synthetic fixture,
then attempts one audit measurement. The follow-up removes the repeat path,
even if all screens pass. Query-plan diagnostics and correctness controls still
run after a failed screen so a performance failure cannot hide their verdict. Do not call either
run a cold-database measurement: the fixture and production baseline warm the
storage engines. Report the first measurement and this limitation explicitly.

Required reports: original fixture/baseline markers, `EXPOSURE_AUDIT_PARITY`,
`EXPOSURE_AUDIT_CAPACITY`, `EXPOSURE_AUDIT_CONTROLS`, named ExUnit result and
canonical observer/teardown/release outcomes. Capacity output includes wall time,
non-overlapping fact time, dimension time, remaining orchestration time, proof
rows/bytes and VM memory at completion. VM memory is not peak RSS. The small
harness retains at most 200 device summaries for oracle comparison; production
adoption must stream these summaries rather than retain a fleet-sized list.

The dimension screen is 120 seconds. The scaled fact and orchestration screens
are 6 seconds and 0.9 seconds respectively; the total fleet deadline remains
900 seconds. A failed screen ends performance experimentation. It does not
justify tuning the codec, widening cohorts, adding workers or requesting the
fleet profile automatically. A pass supports only a separate fleet-run request.

Remote format/quality and normal repository checks are still required before
PR readiness. Publication goes through no-mistakes; this run allocation does
not waive review, Test, lint, hosted PR CI or live validation requirements.

## Authoring evidence and limits

Remote core quality validation passed in
[BuildBuddy](https://carverauto.buildbuddy.io/invocation/c4273d0c-d162-4847-81a0-f9201f0f275d).
That target checks formatting and Credo; it does not execute the manual scratch
prototype or prove its SQL, Ash resources, migration or capacity behavior.
A mistyped initial quality target selected no tests and is not validation.

Ripwire reported clone-shape findings against unrelated production migrations,
a small timing helper and a synthetic fixture transaction helper. Its normalized
SQL-string shapes do not establish interchangeable migrations. The scratch DDL
must not call an unrelated production migration, and fixture trigger control
must not borrow a product remediation writer. These findings remain disclosed;
no blanket acknowledgement or production refactor was used to make them green.
It also flags the benchmark modules' length and dynamically invoked migration
callbacks. Independent no-mistakes review, full repository checks, actual
process-death injection, production restore-hook integration and adopted-runtime
live validation remain pending. The hosted manual execution above does not
replace those checks.

## Approved bounded diagnostic follow-up (not yet executed)

The product owner explicitly approved the recommended follow-up on 2026-10-28
in the native fix decision. The historical source and failed report above remain
unchanged. This follow-up starts from submitted source
`e35474ae115fcf81696db22ba63c4e5dd5780cad`; its eventual hosted execution must
identify its own committed source and exact tree separately.

The disabled harness now batches sorted advisory-lock acquisition into one
round trip per cohort, retaining the same lock IDs and physical DirectSession
through result publication/readiness. The existing busy-device control also
checks caller-order outcomes and lock retention/release from another backend.
No pooled sessions or transaction locks replace the prototype's session locks.

Capacity output adds `summed_worker_ms`: source-fact execution, warehouse-fact
execution, coverage, lifecycle, session start, lock calls including first
checkout, source-view setup, result commit, readiness and deferral commits.
Each cohort attempt is counted once, including proof retries. These inclusive
worker sums overlap and are not wall-clock critical-path durations or CPU time.
The existing elapsed, fact-interval-union, dimension and residual orchestration
counters and every performance assertion remain unchanged. Lazy connection
setup/checkout cannot be isolated from the first lock call at this boundary.

After that single measurement, outside every measured interval, the harness
requests actual `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for source facts and
coverage on the first 32 synthetic devices using the measured run's proofs.
The exact same SQL supplies execution and diagnostic plans. Plans belong in
private execution evidence; only synthetic rounded summaries may be published.
No lookup hoist, CTE removal, width correction or codec change has been made:
physical amplification, copies, spills and replay cost remain unmeasured.
Diagnostic failures and measurement failures are retained while implemented
correctness controls and owned cleanup still execute. There is no repetition.

Execution remains pending. This native Test fix phase prohibits lint/format and
static analysis and does not own the prerequisite format/compile/core-quality
phases. The outer executor must complete those on the committed follow-up before
the one authorized hosted diagnostic allocation. No before/after runtime pass,
current-head plan evidence, cleanup evidence or performance improvement is
claimed by these edits. The supplied historical failure is not a reproduction
on this source. A separate pre-fix run would exceed the one post-commit
allocation, so none was attempted.

Remaining execution: use the existing credential-bound adapter, a fresh unique
prefix/schema, ready generation and canonical serial_2 clone; prove the exact
source/tree; run only this manual target once; inspect both plans; retain every
failed screen and control result; count owned runtime rows empty; verify removal
of warehouse schemas/grants; finish canonical observer/teardown/release. Adapter
runtime/evidence paths must stay within the workspace or the explicitly allowed
private evidence directory, without modifying the checkpoint adapter in place.
Normal unit gate, hosted PR CI and substantive review remain outer-pipeline
requirements. Parent task 1.6 and the fleet gate remain open. The portable
historical report is unchanged because no new measurements exist.
