# Disabled prototype validation result

Status: the one approved hosted small-profile run completed. Its implemented
correctness controls passed, but the fact-comparison performance screen failed.
Performance experimentation stopped; there was no repeat or fleet attempt.
Production adoption and parent task 1.6 remain open. A later explicit approval
allowed the bounded diagnostic follow-up and post-correction verification below,
both now completed. All three measurements failed the fact screen.

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
follow-up below authorized one additional small diagnostic allocation. The latest
decision also authorized one verification of its demonstrated query corrections
after fresh remote quality and compilation; that verification is now complete. Codec tuning, extra workers, wider cohorts, fleet attempts and
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

## Completed bounded diagnostic follow-up

The product owner explicitly approved the recommended follow-up on 2026-10-28
in the native fix decision. The historical source and failed report above remain
unchanged. This follow-up starts from submitted source
`e35474ae115fcf81696db22ba63c4e5dd5780cad`. The
[diagnostic execution](https://carverauto.buildbuddy.io/invocation/a59ce9aa-0b43-4d08-9c00-4545db910dbf)
ran commit `10051ce95d8f0b83f5d234fcded7fb026cd0f140`, exact tree
`7b8b7ee1bd8f71d79e8d7a61966a31bce8f4fa68`.

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
Diagnostic failures and measurement failures are retained while implemented
correctness controls and owned cleanup still execute. There is no repetition.

The supplied diagnostic evidence reports these rounded measurements:

| Measurement | Observed | Result |
| --- | --- | --- |
| Existing production reconciler | 153 seconds | Baseline |
| Complete audit prototype | 36 seconds | Performance screen failed |
| Dimensions | 15 seconds | Below 120-second screen |
| Fact interval union | 13 seconds | Above 6-second screen |
| Residual orchestration | 8 seconds | Above 0.9-second budget; assertion not reached |

Overlapping worker sums were about 24 seconds source, 0.9 seconds warehouse,
11 seconds coverage, 0.4 seconds locks, 0.1 seconds result commit and 1.4 seconds
readiness. These are not additive wall-clock phases. No batching speedup is
established. ExUnit reported one failure, the fact screen. All implemented
controls passed, including lock contention, retention, release and caller order.
Canonical observer, teardown and generation release passed. All five warehouse
tables counted zero in both eligible contexts; schemas and grants were then
verified absent. This evidence belongs to the diagnostic source above.

The coverage plan repeated its generation scan/sort/limit about 163,000 times
for 32 devices without Memoize. Materialized references retained publication
JSON; the query wrote about 7,700 temporary blocks and externally sorted about
9 MiB. EXPLAIN took about 1.8 seconds, including 0.5 seconds JIT. The source
plan took about 3.8 seconds, wrote about 22,000 temporary blocks and retained
wide replay rows in three materialized stages. Inclusive validated, typed and
hashes times were about 2.6, 2.8 and 3.5 seconds, with input about 0.5 seconds;
these times and nested buffer counters must not be summed. Source JIT was about
0.06 seconds. About 510,000 assessment rows were read for about 82,000 cohort
rows on this fixture; this does not predict fleet scan strategy. Raw plans and
runtime records remain private and are not committed.

## Completed post-correction verification

Under design.md's demonstrated-defect stop rule, the latest decision approves
these narrow corrections and one post-correction verification on the same
small workload:

- Materialize the latest covering generation once per requested device, before
  joining expanded reference keys. Preserve descending ID selection, global or
  device scope, and left-join null behavior.
- Materialize only ordinal, CVE ordinal and package-version ordinal in coverage
  references. Preserve assessment/watermark `UNION ALL`, terminal counts,
  invalid-reference rejection, exact proof sequence/hash and oldest proof age.
- Remove forced materialization of source input and typed rows, retaining
  materialized publication validation and hashes. CASE-guarded casts, independent
  current/replay comparison, all typed fields and the v1 codec are unchanged.

The existing decoder parity, drift, terminal-reference, covering-generation,
proof-age and lock controls remained unchanged. No new tests or source-string
checks were added. The earlier diagnostic-source quality/core compilation
[passed](https://carverauto.buildbuddy.io/invocation/199f7d41-6683-447c-800e-becd1ba218e9);
it is historical evidence, not validation of the corrections.

### Execution and report provenance

The [corrected hosted execution](https://carverauto.buildbuddy.io/invocation/bba2e1ab-20d8-47be-a620-5cf2c775db70)
validated execution source `59385424a42dfde36bbf309d7bc7e982a8bd494d`, exact tree
`d285ea04053576e13cf028e7ecb58358a578350f`, verified by hosted preflight.
Fresh remote compilation, formatting and Credo
[passed first](https://carverauto.buildbuddy.io/invocation/6bfc7317-c6a9-49f2-ad3d-af01240f0e69).
Strict OpenSpec and diff checks were also reported passed by the executor.

Report source: this documentation-only revision based on execution source
`59385424a42dfde36bbf309d7bc7e982a8bd494d`. Runtime, test, build and configuration
inputs are unchanged from that execution. The updated report is not an execution
at a subsequent documentation commit. The original and diagnostic executions
above keep their own source IDs and failures.

### Corrected measurement and plans

The same synthetic workload used 200 devices, 500,000 active facts, 10,200
resolved facts and 52,551 dimension proofs, with two workers and cohorts of at
most 32. Only one measurement ran with unchanged controls. The two follow-up
baseline observations both round to 153 seconds. Durations below are rounded;
worker sums overlap and must not be added as critical-path phases.

| Measurement | Diagnostic | Corrected | Verdict |
| --- | --- | --- | --- |
| Complete audit | 35.95 s | 30.85 s | Performance failed |
| Dimensions | 15.38 s | 14.62 s | Below 120 s |
| Cohort interval | 19.70 s | 15.42 s | Inclusive interval |
| Fact interval union | 12.71 s | 11.845 s | Failed 6 s screen |
| Residual orchestration | 7.86 s | 4.377 s | Above 0.9 s; assertion not reached |
| Summed worker coverage | 10.67 s | 4.77 s | Overlapping worker time |
| Summed worker source facts | 23.53 s | 21.91 s | Dominant worker cost |
| Summed worker warehouse facts | 0.85 s | 0.79 s | Overlapping worker time |
| Summed worker locks | 0.42 s | 0.40 s | Includes first checkout |
| Summed worker result commit | 0.11 s | 0.10 s | Overlapping worker time |
| Summed worker readiness | 1.41 s | 1.36 s | Overlapping worker time |

Corrected admission was about 75 ms, finish 8 ms, global readiness 706 ms and
cleanup 5 ms. Summed worker lifecycle was about 42 ms and source-view setup
19 ms. Proof storage was about 53,000 rows / 9.8 MiB; VM memory at completion
was about 168 MiB, not peak memory.

The observed total was roughly 14 percent lower and summed coverage roughly
55 percent lower. One warmed shared-lab pair establishes no p95 or fleet
guarantee. Dimension variation must not be attributed to the SQL correction.
CNPG source work remains dominant.

The corrected 32-device source-fact plan took about 3.69 s, with about 8,000
temporary blocks versus 22,000 before and about 52 ms JIT. Only the validated
and hashes CTEs remain materialized, preserving evaluate-once semantics.
The corrected coverage plan took about 0.86 s versus 1.78 s, with about 340
temporary blocks versus 7,700. The snapshot generation scan ran 32 times versus
about 163,000: per-device lookup and removal of redundant wide copies are now
observed, not hypotheses. The corrected coverage plan has no JIT section; no
JIT configuration changed. EXPLAIN time is separate from measured audit time;
nested timing and buffer counters must not be summed. Raw plans remain private.

### Correctness, cleanup and Test verdict

`EXPOSURE_AUDIT_PARITY` passed 11 cases, two aggregates and two engines.
The complete `EXPOSURE_AUDIT_CONTROLS` marker passed: generated_binding,
replay_drift, late_proof, evidence_age, restore_fence, timeout, expiry, cleanup,
durable_admission, same_count, missing_fact, terminal_reference, new_generation,
grouped_readiness, per_device_failure, busy_device, concurrent_after_images,
empty_device and warehouse_only. Lock controls cover unordered caller outcomes,
busy peer separation, retention during the result callback and availability
after session exit. These are synthetic harness controls, not adopted-runtime
JetStream or snapshot-finalization validation.

ExUnit reported one test and one failure solely: `fact component screen failed;
no fleet attempt`. There was no other error in MultiError. The orchestration
assertion was not reached, although its measured value exceeds the budget.
This is a real performance failure, not a setup failure or a passing Test result.

Canonical observer, teardown and release children succeeded. Every owned
warehouse table counted zero in both eligible contexts before grants were
revoked and schemas dropped. Independent schema-absence and grant-absence reads
passed; all scratch resources are gone.

The Test phase inspected the supplied execution records and confirmed source/tree
identity; it did not rerun the forbidden allocation. Correctness and cleanup have
execution evidence; the performance screen remains FAILED. No thresholds,
expected failures, runtime code, SQL, codec, workers or cohort size changed in
this reporting revision. No new experiment is authorized.

Decision for the outer gate: may this disabled research prototype be published
with the known failed performance screen under an explicit Test exception?
No exception or performance waiver has been granted or inferred. Ordinary full
remote repository tests, hosted PR CI and substantive review remain required
through the outer executor. Cold/repeat/fleet runs, process-death injection,
production restore integration and adoption remain open, as does parent task 1.6.
