# Disabled prototype validation plan

Status: implementation prepared; no behavior or capacity result yet. The
product owner approved implementation on 2026-10-28. Source parsing, remote formatting and strict OpenSpec validation succeeded.
The remote core format/Credo target passed; behavioral execution is still pending. Hosted scratch measurement is
still a separate gate.

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

## Implemented behavior to verify

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
  Gregorian date, fractional precision and offset rules; hosted differential
  cases remain required.
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

## Bounded hosted request

Request one initial hosted validation allocation, scheduled by the coordinator,
using a fresh canonical `serial_2` fixture clone and never-used exposure warehouse
schema on the already-authorized lab warehouse. Use the existing fixture
observer/teardown/release workflow described in
[the live harness runbook](../../../docs/exposure-reconciliation-live-harness.md).
Run the manual audit target explicitly; never enable it for ordinary CI discovery.

The run first verifies the existing production baseline on the synthetic fixture,
then attempts two independent audit runs. The second runs only if the first
passes every component screen. Correctness controls still run after a failed
screen so a performance failure cannot hide their verdict. Do not call either
run a cold-database measurement: the fixture and production baseline warm the
storage engines. Report first/repeat evidence and this limitation explicitly.

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
callbacks. Independent no-mistakes review and hosted execution remain pending.
