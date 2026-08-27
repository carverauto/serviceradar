# Parallel core integration benchmark contract

## Decision this benchmark supports

This benchmark answers whether the ordinary pull-request integration lifecycle is both faster and
safe after source-separating heavy release qualification and enabling bounded in-shard ExUnit
concurrency. It does not measure cold full-repository build time, and it does not treat the focused
heavy action as part of pull-request latency.

The comparison has two named revisions:

- **Before revision:** the corrected instrumentation-only commit that adds the connection observer,
  dedicated `IntegrationBenchmark` BuildBuddy action, an effective-runner configuration marker,
  and the guard that keeps built-in slow-test profiling out of concurrent runs. It is the direct
  parent of the first commit that changes sandbox behavior, source partitioning, test async flags,
  or ordinary target selection.
- **After revision:** the final broad-async implementation commit at `max_cases: 8` after
  concurrency-aware placement.

Both revisions therefore contain the identical benchmark harness, flags, observer, action name,
runner image, workflow pool, explicit CPU request, and Repo pool size 12. A harness hash covers the
normalized action block, observer sources, and observer Bazel rule and is emitted by the checked-in
`//:integration_benchmark_harness_hash` target. The before revision changes measurement only; its
ordinary workload still embeds both ingestion gates plus cold bootstrap and runs with
`max_cases: 1`. The intermediate safety wave reports `max_cases: 2`; the after revision must report
`max_cases: 8`. Neither authoritative action enables
ExUnit's built-in slowest report,
because that option silently enables trace, forces `max_cases: 1`, and changes test timeouts to
infinity. Both preflight and measured database test flags include `--nocache_test_results` and
`--noremote_upload_local_results`; this prevents credential-bearing local TestRunner results from
entering the remote cache and prevents cached results from contaminating cohorts. The exact full
SHAs and harness hash are recorded before any cohort is accepted.

The dedicated action runs only when explicitly requested for the selected commit and never uses a
pull-request merge checkout. Each invocation asserts that its effective `git rev-parse HEAD` equals
the requested commit. The evidence records requested SHA, base SHA (if BuildBuddy reports one), and
effective HEAD so a synthetic merge can never be mislabeled as either cohort.

## Controlled run protocol

Before recording either cohort:

1. Complete the integration-only prebuild for the exact source revision and configuration under
   test. It uses
   `--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test //...`, so Bazel
   warms the measured targets and their transitive dependencies without building unrelated
   packages, release archives, OCI images, or push targets. A second prebuild clears the positive
   tag filter and explicitly warms the four manual targets that run inside the clock:
   `observe_connections`, `sweep_stale_dbs`, `provision_db`, and `teardown_db`.
2. Run the guarded template preparation path. If it reports pending migrations, migrate it and
   repeat preparation in an isolated preflight subshell before starting the clock. The measured
   lifecycle checks the template again but never migrates. If it has become pending, that row is
   retained as warm-up/non-cohort, cleanup runs, and preflight is repeated before another attempt.
3. Confirm the template reports current, the workflow pool is `workflows`, and the runner image is
   the exact image recorded with the cohort.
4. Trigger `IntegrationBenchmark` through `ExecuteWorkflow` with the exact commit and
   `disable_retry: true`. Execute attempts sequentially so the benchmark does not measure
   contention between its own repetitions.
5. Alternate before and after invocations in pairs once both revisions are runnable. This controls
   for time-varying fixture/runner load while retaining the independent ordering of each cohort.
   Unrelated fixture activity is recorded rather than silently discarded.

The exact API request is made without printing the API key:

```bash
curl --fail-with-body --silent --show-error \
  -H "x-buildbuddy-api-key: ${BUILDBUDDY_API_KEY}" \
  -H "content-type: application/json" \
  https://carverauto.buildbuddy.io/api/v1/ExecuteWorkflow \
  --data-binary @- <<JSON
{
  "repo_url": "https://github.com/carverauto/serviceradar",
  "branch": "proposal/parallelize-integration-tests",
  "commit_sha": "${BENCHMARK_SHA}",
  "action_names": ["IntegrationBenchmark"],
  "async": false,
  "env": {
    "SERVICERADAR_BENCHMARK_EXPECTED_SHA": "${BENCHMARK_SHA}"
  },
  "disable_retry": true
}
JSON
```

`BUILDBUDDY_API_KEY` and `BENCHMARK_SHA` must already be set; the request is never run with shell
tracing. The returned invocation id/URL is recorded before the next sequential attempt starts.

Each attempt uses a fresh run id and the CI lifecycle against the development-only
`srql-fixtures` cluster:

```text
sweep -> prepare/current check -> provision -> ordinary integration wildcard -> teardown
```

The clock starts immediately before
`bazel run ... //:buildbuddy_setup_fixture_env` and stops after the matching
`//rust/integration-db:teardown_db` attempt returns, whether it succeeds or fails. The two narrow
prebuilds and template migration are outside the clock. Fixture configuration materialization,
sweep, the current-template check, provisioning, all ordinary integration targets, and
outcome-bearing teardown are inside it. A failed teardown makes the row a failure and its duration
censored: it remains in the attempt log but is excluded from latency statistics because the
required lifecycle endpoint was not reached successfully.

The common measurement flags are:

```text
-c opt
--config=ci
--strategy=TestRunner=local
--//build:enable_integration_tests
--//build:run_id=<fresh-run-id>
--flaky_test_attempts=1
--test_output=all
--nocache_test_results
--noremote_upload_local_results
```

`SERVICERADAR_TEST_SLOWEST` is forbidden in an authoritative timed or gating run. The built-in
report enables ExUnit trace, which forces serial execution and disables test timeouts even when the
target declares another `max_cases` value. Historical slow-case output came from separately labeled
non-cohort profiling runs with `SERVICERADAR_INTEGRATION_MAX_CASES=1`; their lifecycle durations are
never included in either cohort. Under the final placement contract, such output is descriptive
only and cannot refresh source weights or membership. Those come exclusively from the checked-in,
database-free exact selected-test-identity projection.

Both revisions use the same benchmark target selection:

```text
--build_tests_only
--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test
--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test
```

The benchmark contract requires all three flags on the measured `bazel test //...` command.
Test-tag filtering alone prevents excluded tests from executing but still allows Bazel to build
unrelated top-level wildcard targets. The matching build filter plus `--build_tests_only` makes the
in-clock build selection the same 12-target ordinary integration selection warmed before the clock.

The negative Bazel tag changes nothing at the before revision because no target has that tag and
the two ingestion gates plus cold bootstrap are still compiled into ordinary integration shards.
At the after revision it excludes the new dedicated target containing all three heavy suites. The
measured product outcome is ordinary pull-request latency; the gain combines heavy-source
extraction, unit-only source-load pruning, bounded concurrency, targeted test-work reduction, and
rebalancing and must not be described as a pure transaction-concurrency microbenchmark.

## Non-cohort CPU diagnostics

CPU sizing is selected before the authoritative cohorts. On one final-source revision, five
attempts per arm alternate between 2 CPUs and 12 CPUs. Both arms pin
`SERVICERADAR_TEST_DATABASE_POOL_SIZE=12` and otherwise use the same fixed async-plus-serial lane
sources,
the complete ordinary pull-request integration wildcard (including invariant SRQL and other
non-core targets), build warmth, observer, lifecycle, flags, and cleanup. The selected explicit CPU
request must be identical in the before and after accepted harnesses. These diagnostic rows are
not mixed into latency cohorts. The winning request is also applied to production `BazelCI`; an
accepted p95 from capacity different from the pull-request action is invalid.

An arm is selectable only if all five attempts pass every safety/headroom gate. If neither is
selectable, rollout stops; if only one is selectable, it wins. If both are selectable, 12 CPUs wins
only when its untrimmed median lifecycle is at least 10% below the 2-CPU median; otherwise 2 CPUs
wins deterministically. There is no post-result tuning or subjective tie-break.

CPU evidence may carry to the frozen after SHA only when the checked-in
`//:integration_cpu_diagnostic_input_hash` value is identical. That hash covers every selected core
test source, its complete disposition/source map, relevant Bazel/Elixir configuration and helpers,
the PostgreSQL baseline, the integration database lifecycle, the complete invariant SRQL workload,
runner image/pool, and normalized base/CPU2/CPU12 action blocks. It deliberately excludes the later
production-winner CPU field. Both SHA/hash tuples are recorded. A mismatch requires all ten CPU
attempts to rerun after the frozen SHA is published and before the authoritative cohorts.

The production benchmark has no topology challenger matrix. Before the clock starts it freezes
the complete selected source/identity union, exactly one async lane at cap eight, exactly seven
serial lanes at cap one, and pool 12 per lane. This eight-BEAM / 96-core-slot topology was selected
and frozen at proposal time from the audited 197 usable client slots on `srql-fixtures`; production
does not recalculate the lane count from live occupancy. Every lane receives a fresh disposable
`sr_core_test_<run>_<lane>` clone on `srql-fixtures`; demo and production databases are forbidden.

The ordinary wildcard also selects the three pre-existing SRQL integration binaries. Each may
hold a five-connection pool plus its administrator lock connection, so the fixed selected workload
requires 114 slots: 96 for the core topology plus 18 for those unchanged targets. Before readiness,
the observer queries live total server capacity and fails closed unless
`114 <= floor(0.90 * usable_client_slots)`. This check does not enlarge a core Repo pool, add or
remove a core BEAM lane, or subtract current fixture occupancy to derive a smaller topology.

The focused heavy action has a separate capacity contract and does not use the ordinary 114-slot
bound. Its parent `ServiceRadar.Repo` is pinned to 12, and cold bootstrap may concurrently start a
normal child Repo with pool size 2 while the parent remains alive. `StartupMigrations` also opens
one direct Postgrex administrator connection concurrently. The heavy observer therefore requires
15 workload slots before readiness and provisioning. Its own administrator connection is excluded
from that reservation and reported separately. Fifteen is a configured-capacity bound, not a claim
that all 15 sessions are simultaneously active in every sample.

All async sources appear once in the async lane, `load_only` sources appear nowhere, and serial
sources are deterministically LPT-balanced after all `fixed_external` sources preseed `serial_0`.
The source map is input-hashed and cannot change after timing. Runner markers emit `topology`,
`lane`, `max_cases`, `schedulers_online`, effective Repo pool size, trace mode, and timeout mode.
Headroom belongs only to test-supervised processes inside a test BEAM, never deployed applications.

The 259.00-second host-local wave remains directional historical evidence, not an acceptance
baseline. The current ConfigManager CI instance intentionally names in-cluster endpoints that a
workstation cannot reach, while the Rust lifecycle consumes that declared instance rather than the
legacy host/port overrides. Reusing 259.00 seconds would therefore compare different fixture
lifecycle implementations or require an undeclared configuration path.

The hard improvement gate uses the controlled BuildBuddy cohorts that exercise the real CI path:

- required relative improvement:
  `(before_p95 - after_p95) / before_p95 >= 0.50`;
- stretch relative improvement: at least `0.60`;
- required absolute after p95: at most `90.0s`.

Before spending the full cohorts, one retry-free exact-SHA `IntegrationBenchmark` smoke must pass
the final harness, complete outcome-bearing teardown, and every isolation, connection-headroom,
marker, and residue check. A future workstation benchmark requires a Bazel-declared ConfigManager
fixture identity plus a newly measured before cohort; it cannot inherit the historical 259.00-
second baseline.

## Metrics and calculations

Every attempt records:

- requested source SHA, effective HEAD, reported base SHA, benchmark-action hash, BuildBuddy
  invocation URL, run id, runner image, pool, and UTC start/end;
- lifecycle seconds from the clock boundary above;
- TestRunner duration for the async target and every selected serial-lane target;
- each lane's `SERVICERADAR_INTEGRATION_RUNNER` startup marker, proving topology, lane, declared
  `max_cases`, `System.schedulers_online()`, effective Repo pool size, trace mode, and timeout mode
  used by that execution;
- maximum sampled run-scoped and fixture-wide PostgreSQL connections, with sample interval,
  observer-session exclusion count, and observer UTC sample-window start/end;
- live `max_connections`, `superuser_reserved_connections`, optional `reserved_connections`, and
  derived usable client slots;
- suite result, observer result, teardown result, Bazel retry count, workflow retry count,
  effective-HEAD assertion, and failure classification.

The checked-in Bazel-owned connection observer samples `pg_stat_activity` every 500 milliseconds.
Run-scoped connections are sessions whose database name either equals the guarded run's disposable
base database or begins with that base followed by the literal `_` lane delimiter. The query uses
`datname = $1 OR left(datname, char_length($1) + 1) = $1 || '_'`; it MUST NOT use an unescaped SQL
`LIKE` pattern or an unbounded raw-prefix comparison. This prevents adjacent manual run IDs such as
`deadbeef` and `deadbeef1` from sharing observer counts. Fixture-wide connections are all
non-background sessions on the fixture. The observer starts after fixture
configuration is materialized and before provisioning, waits for a bounded ready handshake before
the lifecycle continues, and stops after teardown. Ready/suite/quiescent/stop paths are initially
absent children of one private temporary directory; they are never pre-created with `mktemp`.
Its one administrator session is emitted as
`observer_sessions_excluded: 1` and excluded by backend PID from both sampled counts. The summary
also emits UTC epoch-millisecond `sample_window_start_ms` and `sample_window_end_ms`. The metric is
explicitly a maximum sampled value, not a claim that a 500 ms poll observes every sub-interval
spike. It also queries the live capacity settings rather than assuming the committed CNPG manifest
is the server currently under test. Unrelated live fixture sessions remain included in the
fixture-wide samples; only the observer's own reported session is excluded. Live occupancy is
therefore recorded as evidence, not subtracted from total server capacity to resize the topology.

After the suite exits, the action writes its suite-complete marker and waits for the observer's
quiescent marker before teardown starts. The observer writes that marker only after zero run-scoped
client connections for two consecutive samples. That is the executable leaked database-process check:
Repo pools and their test-owned children must be gone when each BEAM exits. Non-database BEAM
processes cannot survive the TestRunner VM boundary. Teardown then verifies that no database under
the run prefix remains.

Statistics use the raw values without trimming outliers:

- median is the average of ordered values 10 and 11;
- nearest-rank p95 is ordered value 19 of 20;
- per-attempt serial-lane skew is `max(duration) / min(non-empty serial-lane duration)`;
- relative p95 improvement is `(before_p95 - after_p95) / before_p95 * 100`.

An infrastructure event may be classified separately only when the logs prove the test lifecycle
never started, such as a workflow pod scheduling failure. Once fixture materialization starts, the
attempt remains in the all-attempts record. Each accepted cohort is 20 consecutive successful
lifecycle attempts at its revision. A test, ownership, deadlock, leaked-process, leaked-database,
teardown, Bazel retry, workflow retry, or effective-HEAD failure breaks that revision's sequence;
the failure row remains and the 20-attempt acceptance sequence restarts after a fix. The evidence
table may therefore contain more than 40 rows. A behavior fix after the after SHA is frozen creates
a new after revision, requires the exact-SHA/harness checks again, and restarts the after sequence;
rows from the superseded revision remain labeled in the record. The unchanged before cohort need
not be discarded unless the measurement harness itself changes.

## Goals and stop conditions

The implementation is accepted only when all of these are true:

| Dimension | Required result |
| --- | --- |
| Ordinary lifecycle latency | After nearest-rank p95 is at most 90.0 seconds |
| Relative improvement | After p95 at least 50% below before p95; report whether the 60% stretch passes |
| Stability | 20 consecutive before and 20 consecutive after attempts pass with no Bazel or workflow retries |
| Isolation | Zero sandbox ownership errors or cross-owner visibility failures |
| Database locking | Zero PostgreSQL deadlocks |
| Cleanup | Two consecutive zero run-scoped samples before teardown and zero disposable databases after teardown |
| Balance | Every after attempt has serial-lane skew at most 1.5 |
| Topology | Exactly one async BEAM at cap 8 plus exactly seven serial BEAMs at cap 1; Repo pool size exactly 12 per BEAM and exactly 96 configured core slots |
| Runner capacity | Identical explicit CPU request in before/after; runner markers prove schedulers and pool |
| Run-scoped connections | Peak at most 114: the fixed 96-slot core envelope plus 18 connections for the three selected SRQL binaries |
| Fixture-wide connections | Maximum sampled value, including unrelated fixture sessions and excluding only the observer's reported session, at most `floor(live usable client slots * 0.90)` |
| Heavy capacity | Parent Repo pool 12 plus concurrent cold-bootstrap child Repo pool 2 plus one direct `StartupMigrations` Postgrex administrator connection; observer requires 15 workload slots before readiness and provisioning |
| Heavy coverage | Both ingestion gates and intact cold bootstrap pass in the focused lifecycle |

The report always includes before/after median, p95, relative delta, and whether the 60% relative
stretch threshold passed. The 90-second BuildBuddy bound, 50% BuildBuddy relative bound, and every
required row in the table above are acceptance criteria. Any safety threshold failure stops rollout; the cap returns to
the candidate is invalidated and no cohort restarts. An ownership or classification defect moves
the offending module to the serial disposition, regenerates the manifest-backed map and hashes,
and creates a new exact-SHA candidate. A balance-only failure requires an OpenSpec amendment before
any timing-derived profile or membership change; cap fallback is not part of the fixed topology.

## Evidence record

### Rejected prebuild-only attempts

Two 2026-08-24 attempts at candidate `16024dc890f050fd806a41cce0900a75f2777d0c`
ended before fixture materialization and are not timing or safety rows. Parent
`4a49c462-d08a-49a8-8b0b-9643d79fb754` failed to create a workflow invocation when Kubernetes
rotated the sole workflow executor. Parent `798d3c24-6516-4f5b-9a30-753ad6b1190e` reached child
`ad48569c-b333-48c0-99d8-0c3ca4631927`, exposing that the provisional prebuild used unfiltered
`bazel build //...` and therefore built packages, release archives, and OCI images unrelated to the
integration selection. That parent was canceled before database preflight or `START_NS` and the
prebuild was replaced by the two narrow commands defined above. Neither attempt can enter a
benchmark cohort.

### Rejected broad measured-wave attempt

The 2026-08-24 exact-SHA smoke at candidate
`58589a1183c5e4549fae6ae097bc7e9ec4c233e5`, parent invocation
`c85e45ca-cdc7-4281-a593-63caaa56cc53`, passed all 12 ordinary integration tests and outcome-bearing
teardown. The observer reported run-scoped peak 96, fixture-wide peak 97 of 197 usable client slots,
and zero suite, observer, and teardown statuses. Its two prebuild children correctly built exactly
12 integration targets and four lifecycle helpers.

The measured wildcard child `faef069c-0a99-4d59-8265-1e641ab2fdcc` nevertheless exposed a second
selection defect: `--test_tag_filters` prevented unrelated tests from running but, without
`--build_tests_only` and the matching `--build_tag_filters`, Bazel built 1,586 top-level targets and
74,496 actions, including package and OCI-image targets. The child lasted 82.990 seconds and the
guarded lifecycle lasted 122.969 seconds. Those times are rejected because unrelated build work ran
inside the clock. The successful test and cleanup results remain non-timing safety evidence. The
measured command now carries all three selection flags above; this attempt cannot enter a benchmark
or CPU-diagnostic cohort.

Historical observations motivated the work but are not the controlled before cohort. Five recent
successful pull-request integration phases ranged from 141 to 262 seconds. A separately inspected
2026-08-23 run lasted approximately 183.4 seconds across fixture materialization through teardown;
its shard durations were 107.8, 147.3, 62.3, 77.0, 58.1, 69.1, 68.1, and 59.2 seconds. That run is
available at
<https://carverauto.buildbuddy.io/invocation/6b474999-9800-4806-9af7-52fd70a352c6>.

These values are context only because they come from different revisions and were not executed as
one controlled cohort.

### Invalidated initial harness

The first frozen-before candidate, `2dfe04f78c87982af0730768b09acc932658ec32`, emitted harness
hash `4fc39b452ee3b380b116d87e8a54799169da558d7d4e45bca7129b5773c75c95`. It is not an admissible
before revision. Its benchmark action set `SERVICERADAR_TEST_SLOWEST=15`; ExUnit converted that to
trace mode, forced `max_cases: 1`, and disabled test timeouts. A corrected instrumentation-only
before commit is cut from that candidate, then the behavior commits are replayed so the corrected
before remains the direct parent of the change. Both cohort identities and the replacement harness
hash remain pending until that history repair is complete. No timing row collected with the
invalidated harness can enter an acceptance statistic.

### Non-cohort local diagnostic

A host-local diagnostic provided directional partitioning evidence before the controlled
BuildBuddy cohorts. It ran eight concurrent `mix test --no-compile` processes using Bazel shard
source membership and one template-cloned database per shard. The reconstructed "before layout"
used the post-extraction candidate source tree; it was not the frozen before revision. The
checked-in pool size remained 12 and the integration environment requested `max_cases: 2`, but
every wave also set `SERVICERADAR_TEST_SLOWEST=15`. That option enabled ExUnit trace, forced the
effective `max_cases` to one, and disabled ExUnit timeouts. The one-scheduler BEAM limit controlled
workstation oversubscription but did not cause the serialization.

The reconstructed before layout completed five green waves: 10,125 test executions, zero failures,
and zero run-specific databases remaining after cleanup.

| Before wave | Critical path (s) | Shard skew | Result |
| --- | ---: | ---: | --- |
| B1 | 440.898 | 5.576 | 2,025 tests, 0 failures |
| B2 | 458.110 | 4.718 | 2,025 tests, 0 failures |
| B3 | 425.968 | 5.780 | 2,025 tests, 0 failures |
| B4 | 420.278 | 5.574 | 2,025 tests, 0 failures |
| B5 | 420.788 | 5.448 | 2,025 tests, 0 failures |

The median before critical path was 425.968 seconds. The first measured-weight layout candidate also
passed all 2,025 tests and left zero run-specific databases. Its shard durations were 265.048,
206.228, 217.746, 221.471, 193.199, 230.968, 171.368, and 242.066 seconds; the complete local wrapper
elapsed in 265.086 seconds. Relative to the before-layout median, its shard critical path was 37.8%
shorter:

```text
(425.968 - 265.048) / 425.968 * 100 = 37.8%
```

That result did not meet the balance threshold: its shard skew was
`265.048 / 171.368 = 1.547`, narrowly above the required 1.5 maximum. It is also superseded as
candidate evidence because the allocator workload was subsequently corrected from an arbitrary
300 identities to 258, exactly one beyond its 257-identity legacy boundary. Its source weight and
layout must be remeasured against the corrected workload.

Two later local waves reached teardown and are retained as failed diagnostic rows. A finer
four-weight fit ran for 394.311 seconds and reached raw shard walls between 290.055 and 394.286
seconds, but three shards exited red with SQL checkout pressure. Restoring the first candidate and
retrying after an idle-fixture preflight ran for 381.682 seconds, but four shards exited red with
the same checkout-drop class. The 101-735ms drops match DBConnection's shared-owner proxy queue,
not exhaustion of the 12-connection Repo pool. Because trace had disabled ExUnit's 300-second test
timeout, the allocator instead reached the independent 360-second SQL Sandbox ownership deadline
(the test tag plus the checked-in 60-second owner margin). Exact-name teardown left zero databases
after both failed waves. Neither row contributes to latency or balance acceptance.

These observations are not an acceptance cohort. Host-native Bazel execution was unavailable
because the integration target has Linux-only runtime dependencies, so the diagnostic used local
Mix processes rather than the checked-in BuildBuddy action. It did not compare frozen exact-SHA
revisions on the CI runner image, alternate revisions, collect the connection-observer/retry
metadata, or produce 20 consecutive successful attempts per revision. Five before samples and one
green after sample cannot establish the required p95. The repeated checkout failures are a safety
finding to resolve before freezing the after SHA, not noise to exclude. Controlled exact-SHA
BuildBuddy evidence and the final acceptance decision remain pending.

### Actual-concurrency local control

A fresh control then omitted slowest reporting, held the Repo pool at 12, limited each local BEAM to
two schedulers, and ran the provisional `[1, 30, 55, 107, 143, 143, 143, 143]` source layout. Every
shard emitted `max_cases=2 trace=false timeouts=enabled`, so this wave exercised the intended inner
concurrency for the first time. Exact-name cleanup again left zero run-specific databases.

| Shard | Wall (s) | Tests | Result | Queue-drop messages |
| --- | ---: | ---: | --- | ---: |
| s0 | 309.379 | 3 | 1 failure (300s allocator timeout) | 0 |
| s1 | 357.287 | 94 | 2 failures | 3 |
| s2 | 376.872 | 181 | 0 failures | 1 |
| s3 | 399.936 | 250 | 0 failures | 0 |
| s4 | 349.574 | 424 | 1 failure | 1 |
| s5 | 399.089 | 350 | 5 failures | 4 |
| s6 | 304.079 | 387 | 3 failures | 9 |
| s7 | 438.314 | 336 | 1 failure | 2 |

The control is red: six shards had test failures and the logs contained 20 queue-drop messages.
Two of the s6 failures were the nominally concurrent remote-access tests; their four tasks shared
one boxed Sandbox owner and therefore one connection. This proves that increasing the outer pool
cannot make those tests concurrent. They require per-test unboxed execution, distinct backend
connection/lock-wait proof, and failure-safe exact cleanup.

The allocator control supplied a deterministic RED for a scoped optimization. The exact
258-identity boundary test was changed to run unboxed with at most ten connections, retaining two
slots of headroom in the unchanged pool. A fresh focused run then completed all three module tests
in 39.867 seconds with zero failures, queue drops, timeouts, or database residue. This is an 87%
reduction relative to the 309.379-second timed-out shard wall, but it is focused evidence only. Its
rounded provisional weight of 40 produces source counts
`[17, 42, 92, 94, 130, 130, 130, 130]`; a green full wave and consistent-mode profiling remain
required.

A focused shared-owner regression also reproduced the queue mechanism without suite load: while a
legitimate child held the owner's connection for 1.25 seconds, the default proxy dropped the
waiting query after 984ms. That RED justifies testing one finite `queue_target=1000` /
`queue_interval=1000` treatment. With those defaults, the initial focused treatment emitted
`max_cases=2 trace=false timeouts=enabled` and completed in 1.5 seconds (one test, zero failures);
exact-name teardown left zero database residue. The regression was subsequently hardened with an
observed ownership-queue barrier before starting its 1.25-second hold; that version participated in
the complete treatment wave, which recorded zero queue drops. The treatment preserves the Repo
pool size and environment overrides. It does not justify ratcheting the queue toward the existing
20-second fixture override, and a green full wave remains required.

### Actual-concurrency local treatment

The next complete local wave used the corrected source counts
`[17, 42, 92, 94, 130, 130, 130, 130]`, pool size 12, two schedulers and `max_cases=2` per BEAM,
trace off, finite timeouts, and no retries. Every shard emitted the effective-runner marker. The
shared template matched this checkout's latest migration (`20260821180000`), and eight exact-name
clones were sampled once per second.

| Shard | Wall (s) | Tests | Result |
| --- | ---: | ---: | --- |
| s0 | 400.03 | 29 | 1 failure: database-bootstrap 300s timeout |
| s1 | 590.59 | 86 | 1 failure: ingestor-conflict 180s timeout |
| s2 | 691.95 | 310 | green |
| s3 | 666.84 | 247 | green (2 skipped) |
| s4 | 759.96 | 383 | 1 failure: 100ms lock-holder synchronization bound |
| s5 | 725.57 | 340 | green |
| s6 | 544.74 | 319 | green |
| s7 | 573.77 | 312 | green (4 skipped) |

The safety signal improved materially: five shards were green, queue drops fell from 20 to zero,
and the wave had zero deadlocks and zero sandbox ownership errors. Peak run-specific connections
were 97 against `max_connections=200` with three superuser-reserved slots (49.2% of 197 usable
slots), all sessions became quiescent, and exact-name teardown left zero databases.

The latency result is not acceptable: the critical shard was 759.96 seconds, 73.4% slower than the
red control's 438.314-second wall, and three tests still failed. The red control is not a valid
performance baseline because early failures skipped work, but the treatment independently exceeds
the 90-second absolute goal by a wide margin. Two failures identify fixture-intensive serial work
that slows sharply under eight-shard load; the third exposed an invalid default 100ms process
synchronization assertion and was changed to an explicit five-second bound after this wave. The
exact identity-race case then completed a fresh focused run in 4.6 seconds (one test, zero failures)
with exact-name cleanup. That is directional correctness evidence only; none of the follow-up
changes is accepted until another complete wave is green.

Follow-up investigation separated two different kinds of serial cost:

- The conflict test's 130 handlerless duplicate ingests did not traverse the separate
  128-generation marker window. The same two payload digests reuse their persisted generations,
  while the dedicated handler-generation suite covers actual generation changes. Replacing the
  redundant loop with one replay of each digest plus fixed-point assertions reduced the module
  from 156 to 28 end-to-end ingests without removing either arrival order or state-repair check.
  A fresh trace-free `max_cases=2` run completed the changed case in 14.62 seconds and the full
  four-test module in 51.79 seconds, both with zero failures and exact-name cleanup residue zero.
- Cold database bootstrap is irreducibly sequential at the test level: its first startup applies
  the committed baseline plus the remaining migration history, and its second startup is the only
  coverage of the normal migrated restart branch. Its provisional quiet serial cost of roughly
  115 seconds already exceeds the complete 90-second PR goal; under the treatment, the first pass
  exceeded 300 seconds. The test is therefore moved intact out of every ordinary shard and into
  the existing source-separated default-branch/nightly/release qualification target. This changes
  scheduling, not assertions, and avoids creating an impossible sequential PR floor.

With bootstrap removed from ordinary source membership and the focused conflict-module weight
rounded to 52, the next provisional least-estimated-load layout has source counts
`[61, 73, 75, 111, 111, 111, 111, 111]`. The counts are not runtime evidence; the estimated loads
are balanced by the checked-in weights, which still mix focused and earlier serial profiling
modes. Another complete diagnostic wave and one consistent profiling pass are required before the
after revision can be frozen.

A direct target-equivalent serial qualification then loaded exactly the two release-gate sources
plus cold bootstrap against a fresh template clone, with the production 50,000-device and
500-device/three-round values. It emitted
`max_cases=1 trace=false timeouts=enabled` and completed in 407.61 seconds: three tests, zero
failures, no bootstrap cleanup warning, zero dedicated-database residue, and zero newly remaining
`sr_core_test_bootstrap_*` database. This is 22.6% of the observer and release qualifier's
1,800-second budgets. A preceding diagnostic that deliberately supplied a 20-second sandbox-owner
timeout failed only the cardinality test and is excluded from timing evidence; removing that
non-target override produced the green result above. The actual BuildBuddy guarded lifecycle still
must run repeatedly before heavy-gate status publication is accepted. This direct run did not
exercise or record the corrected guarded observer preflight at 15 workload slots, so it does not
satisfy pending Tasks 2.6 or 5.6.

### Corrected-layout green ordinary wave

The first complete ordinary wave after source-separating bootstrap, reducing the redundant
conflict workload, and fixing the identity synchronization bound used source counts
`[61, 73, 75, 111, 111, 111, 111, 111]`. It retained the actual-concurrency contract: pool size 12,
two schedulers and `max_cases=2` per BEAM, trace off, finite timeouts, no retries, eight fresh
template clones, and one-second connection sampling.

| Shard | Wall (s) | Tests | Result |
| --- | ---: | ---: | --- |
| s0 | 169.85 | 144 | green |
| s1 | 137.33 | 154 | green (2 skipped) |
| s2 | 239.28 | 288 | green |
| s3 | 199.38 | 296 | green |
| s4 | 165.60 | 223 | green |
| s5 | 163.73 | 293 | green |
| s6 | 255.60 | 369 | green |
| s7 | 155.28 | 258 | green (4 skipped) |

All eight shards completed in 259 seconds: 2,025 tests, zero failures, zero queue drops, zero
ownership errors, and zero deadlocks. The peak was 97 run-specific connections and 124 fixture-wide
connections. Against 197 usable fixture slots, those are 49.2% and 62.9%, respectively. Exact-name
cleanup left zero run databases.

This is the first complete green treatment and a material directional improvement: its
255.60-second critical shard is 66.4% below the preceding red treatment's 759.96-second critical
shard. The failed treatment is not an accepted latency baseline, so that delta is diagnostic rather
than the final before/after result. The absolute and balance goals still fail locally: one wave
cannot establish p95, the critical shard exceeds 90 seconds, and real-time shard skew is
`255.60 / 137.33 = 1.86`, above 1.5. A consistent profiling wave must now replace the remaining
mixed scheduling hints before the after revision is frozen.

A profiling-only follow-up ran the two critical shards with
`max_cases=1 trace=true timeouts=infinity profiling_only=true`. Both were green and exact cleanup
left zero databases. Complete trace aggregation, rather than only the displayed top 25 cases,
identified these provisional per-file weights:

| Source | Rounded weight |
| --- | ---: |
| `notifications/seeder_reconciliation_test.exs` | 79 |
| `observability/plugin_result_ingestor_conflict_test.exs` | 52 |
| `edge/agent_config_generator_test.exs` | 42 |
| `network_discovery/mapper_graph_ingestion_test.exs` | 40 |
| `observability/plugin_result_slot_allocator_test.exs` | 40 |
| `notifications/dispatcher_delivery_test.exs` | 33 |
| `sweep_jobs/sweep_results_flow_e2e_test.exs` | 32 |
| `edge/agent_release_manager_test.exs` | 30 |
| `notifications/dispatcher_routing_test.exs` | 25 |
| `composite_checks/evaluation_test.exs` | 19 |
| `observability/stateful_alert_engine_test.exs` | 19 |
| `plugins/producer_schedule_test.exs` | 15 |
| `edge/remote_access_sessions_test.exs` | 14 |
| `notifications/action_redemption_test.exs` | 13 |

The two focused weights remain mixed-mode until the required all-shard serial profile. Applied
provisionally, LPT estimates loads `[151, 150, 151, 150, 150, 150, 151, 150]` with source counts
`[73, 99, 98, 97, 98, 100, 96, 103]`; the eight largest files start one per shard and fixed
external-resource sources remain in `s7`.

Rebalancing alone cannot reach 90 seconds in this local environment. The green wave reported
1,398.6 aggregate synchronous ExUnit seconds, a perfect eight-way floor of 174.8 seconds before
runner overhead. BuildBuddy is the authoritative environment and has historically run these cases
faster, so this does not pre-judge its p95; it does prove that a local 90-second result would require
substantially more audited overlap, work reduction, or source separation rather than finer LPT
weights alone.

The resulting trace-free diagnostic layout was safe and faster again, but not balanced:

| Shard | Wall (s) | Tests | Result |
| --- | ---: | ---: | --- |
| s0 | 208.30 | 219 | green (2 skipped) |
| s1 | 102.35 | 242 | green |
| s2 | 215.28 | 308 | green |
| s3 | 192.38 | 169 | green |
| s4 | 148.59 | 352 | green |
| s5 | 140.16 | 204 | green |
| s6 | 130.71 | 205 | green |
| s7 | 229.29 | 326 | green (4 skipped) |

All 2,025 tests passed in a 233-second wave with zero queue drops, ownership errors, deadlocks, or
database residue. Peak run-specific connections fell to 96 and fixture-wide peak remained 124.
The critical shard improved another 10.3% from 255.60 to 229.29 seconds, but skew worsened to
`229.29 / 102.35 = 2.24`: `s1` became too light while `s2` and `s7` retained unmeasured cost. This
rejects hand-tuning a mixed-mode map. The next partition must come from one all-eight profiling
wave in a single mode before another trace-free test.

That all-eight profiling wave then ran every shard concurrently with
`max_cases=1 trace=true timeouts=infinity profiling_only=true`. Complete trace aggregation recorded
3,115.542 case-seconds across 273 files. Seven shards were green; `s5` exposed one deterministic
test-clock defect in `dispatcher_delivery_test.exs`. Production stamps a dispatch attempt's
`started_at` from the real clock, while the test computed its stale cutoff from an earlier synthetic
`now`. The trace overhead made that ordering visible. The exact traced case was red before the fix;
anchoring the cutoff to the persisted `started_at` then passed five consecutive traced repetitions
in 18.76 seconds. Because the original profiling wave was not entirely green, it remains diagnostic
rather than acceptance evidence, even though the failed assertion did not invalidate the other
case timings.

The consistent trace replaced the mixed map with rounded per-file weights for all 30 sources at or
above a 25-second cutoff. Sources below the cutoff retain the common weight of one. LPT now estimates
shard loads at 339--340 units and produces source counts
`[93, 94, 94, 93, 94, 95, 101, 100]`; the eight largest sources start one per shard and the fixed
external-resource sources remain on `s7`. The checked-in topology test proves deterministic,
disjoint placement independently of glob order.

The resulting trace-free validation wave used the same local treatment contract as the two green
waves above: eight fresh template clones, pool size 12, two schedulers and `max_cases=2` per BEAM,
trace off, finite timeouts, and no retries.

| Shard | Wall (s) | Tests | Result |
| --- | ---: | ---: | --- |
| s0 | 202.96 | 207 | green |
| s1 | 140.59 | 223 | green |
| s2 | 176.22 | 241 | green (2 skipped) |
| s3 | 198.53 | 260 | green |
| s4 | 195.72 | 272 | green |
| s5 | 183.79 | 267 | green |
| s6 | 198.39 | 327 | green |
| s7 | 182.71 | 228 | green (4 skipped) |

All 2,025 tests passed in 203.02 seconds with zero queue drops, ownership errors, deadlocks, or
database residue. Every shard emitted
`max_cases=2 trace=false timeouts=enabled`. Skew is `202.96 / 140.59 = 1.444`, meeting the local
balance goal of at most 1.5. Relative to the immediately preceding identical-mode wave, wall time
improved from 233 to 203.02 seconds (12.9%) and critical path improved from 229.29 to 202.96 seconds
(11.5%). Relative to the first complete green treatment, wall time improved from 259 to 203.02
seconds (21.6%) and critical path from 255.60 to 202.96 seconds (20.6%).

This validation did not run the connection observer, so it makes no new peak-connection claim; the
preceding identical-concurrency wave remains the latest sampled evidence at 96 run-specific and 124
fixture-wide connections. The topology, pool sizes, and concurrency caps did not change. The local
203.02-second result is directional evidence, not the 20-run BuildBuddy p95 acceptance cohort, and
does not satisfy the separate absolute 90-second CI goal by itself.

### Approved broad-async continuation

The 203.02-second wave is an intermediate result, not completion. The selected inventory contains
222 ordinary DataCase modules: 220 declare `async: false` and only two declare `async: true`. The
two source-separated large-ingestion DataCase modules are not part of this ordinary count. The two
promoted ordinary database sources are assigned to different shards, so their conversion does not cause the
new database modules to overlap each other. The 21.6% gain therefore came primarily from extraction,
test-work correction, and placement.

The subsequent semantic audit identified roughly 1,150 trace-instrumented case-seconds that may
become async after full-module promotion, mixed-module splitting, and test-local identifier
normalization. Those values are relative placement weights only. They MUST NOT be subtracted from
the 1,398.6-second trace-free aggregate or converted into cap-two, cap-eight, or one-BEAM wall-time
forecasts. The CPU, topology, historical cap-two, frozen cap-eight, local, and exact-SHA protocols
remain the only comparable measurements used for decisions.

### Corrected exact-SHA harness smoke and structural lane rebalance

The first exact-SHA smoke after constraining both build and test selection ran commit
`a6fde460627429338adb76e21884c49cd7c257cf`. Its prebuild selected exactly the 12 intended
integration targets plus four lifecycle helpers. The timed child built 27 actions, selected exactly
12 tests, and completed in 52.521 seconds; the complete measured fixture lifecycle was 86.480
seconds. All 12 targets passed on attempt one, teardown succeeded, the observer reported run and
fixture peaks of 96 and 97 connections, and filtered logs contained no ownership error, deadlock,
queue-drop, or residue evidence. This is the first valid absolute-goal smoke, but it is not an
authoritative before/after cohort.

Its serial target walls were 24.518, 29.134, 34.318, 40.283, 45.047, 33.858, and 30.578 seconds.
The resulting `45.047 / 24.518 = 1.837` skew fails the required 1.5 balance gate. Inspection showed
that all 159 serial sources had exactly one selected module, making the old
`1 + selected_serial_module_count` weight uniformly two. The candidate therefore implemented
alphabetical source-count round-robin, not meaningful LPT. The smoke is retained as safety and
harness evidence but invalidates that source map.

The replacement uses no wall-time measurement. The existing database-free selection runners emit
the exact `(source, module, test-name)` union selected by ExUnit's real filters. A checked-in
159-source projection is now executable-contract-checked against all 1,316 serial identities and
feeds deterministic LPT weight `1 + selected_serial_test_identity_count`. Before another fixture
smoke, the new map has these structural properties:

| Lane | Sources | Selected test identities | Structural load |
| --- | ---: | ---: | ---: |
| `serial_0` | 26 | 185 | 211 |
| `serial_1` | 22 | 190 | 212 |
| `serial_2` | 21 | 189 | 210 |
| `serial_3` | 22 | 188 | 210 |
| `serial_4` | 22 | 188 | 210 |
| `serial_5` | 23 | 188 | 211 |
| `serial_6` | 23 | 188 | 211 |

All three fixed-external sources remain confined to `serial_0`; reversed source input produces the
same map. Structural selected-test skew is 1.027 and load skew is 1.010. These are placement
invariants, not runtime forecasts. The harness hash remains
`28ab9a0e7fa0c7c4149afbfeb25393028bebffbabc2007672244979847e7491f`; the rebalance changes the
CPU-diagnostic input hash to
`52c29d6571d0674e6c70dae8dfe18f64bb76cd1d64ed66d71b0e8c696059f817`. A fresh exact-SHA smoke
still must prove the runtime skew and all safety criteria before CPU diagnostics or authoritative
cohorts begin.

### Rebalanced structural-map exact-SHA smoke

The replacement-map smoke ran exact SHA
`75f8fec704d56cafeec8fc9f618d99a44575c48b` with the hashes above. Parent invocation
[`29f24280-f961-461a-89d3-2ed76153aa7f`](https://carverauto.buildbuddy.io/invocation/29f24280-f961-461a-89d3-2ed76153aa7f)
checked out that SHA and produced measured-suite child
[`b8c66a83-52ff-4f5a-ab46-5daf01794068`](https://carverauto.buildbuddy.io/invocation/b8c66a83-52ff-4f5a-ab46-5daf01794068).
The child selected exactly the intended 12 integration targets, excluded packages and OCI images,
ran every target once with `run=1`, `shard=1`, and `attempt=1`, and passed in 75.872 seconds. The
complete guarded lifecycle ran from `2026-08-24T05:48:11Z` through `2026-08-24T05:50:12Z` and took
120.862 seconds.

| Lane | Selected test identities | Target wall seconds | Effective runner marker |
| --- | ---: | ---: | --- |
| `async` | 714 | 60.570 | cap 8, schedulers 30, Repo pool 12 |
| `serial_0` | 185 | 42.729 | cap 1, schedulers 30, Repo pool 12 |
| `serial_1` | 190 | 44.955 | cap 1, schedulers 30, Repo pool 12 |
| `serial_2` | 189 | 49.417 | cap 1, schedulers 30, Repo pool 12 |
| `serial_3` | 188 | 49.168 | cap 1, schedulers 30, Repo pool 12 |
| `serial_4` | 188 | 40.221 | cap 1, schedulers 30, Repo pool 12 |
| `serial_5` | 188 | 46.088 | cap 1, schedulers 30, Repo pool 12 |
| `serial_6` | 188 | 45.335 | cap 1, schedulers 30, Repo pool 12 |

All eight markers also reported `trace=false` and `timeouts=enabled`. The 2,030 Elixir tests had
zero failures. Exact runtime serial-lane skew was `49.417 / 40.221 = 1.229`, improving the
invalidated map's 1.837 skew and passing the 1.5 gate. Filtered lane logs contained zero ownership
or owner-exit errors, SQLSTATE `40P01` or deadlocks, queue drops, pool exhaustion or checkout
timeouts, database-isolation/connectivity failures, and process crashes. Generic error strings were
only expected negative-path fixtures asserted by their tests.

Run id `3a4b7d76` used disposable prefix `sr_core_test_3a4b7d76`. The observer sampled 211 times at
500 ms, excluded its one administrator session, and reported run-scoped peak 96 and fixture-wide
peak 97 against 197 usable client slots (`max_connections=200`, three superuser-reserved, zero
general-reserved). Suite, observer, and outcome-bearing teardown statuses were all zero, with no
process or database residue. This accepts the structural source map for CPU diagnostics. It is a
non-cohort smoke: its 120.862-second lifecycle neither passes nor fails the separate requirement
that the final accepted 20-run after cohort have nearest-rank p95 at most 90 seconds.

Authoritative evidence first records cohort metadata:

| Cohort | Requested SHA | Effective HEAD | Reported base SHA | Harness hash | Runner image | Workflow pool | CPU request | Repo pool | Schedulers | Sample ms | Observer sessions excluded | Max connections | Superuser reserved | General reserved | Usable slots |
| --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |

Every started attempt then uses this schema. The invocation contains the effective-runner marker
and observer window; the summary columns keep every threshold independently recomputable:

| Cohort | Attempt | Invocation | Run id | Topology | Lane/cap marker | UTC start | UTC end | Observer UTC start | Observer UTC end | Lifecycle s / censored | async | serial_0 | serial_1 | serial_2 | serial_3 | serial_4 | serial_5 | serial_6 | Skew | Run sampled peak | Fixture sampled peak | Pre-teardown zero samples | Bazel retries | Workflow retries | Suite | Observer | Teardown | Classification |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |

The completed change appends every attempt row, including failed sequences, followed by the
accepted 20-row before/after medians, p95 values, relative delta, maximum skew, sampled connection
peaks, and acceptance decision.
