# Parallel core integration benchmark contract

## Decision this benchmark supports

This benchmark answers whether the ordinary pull-request integration lifecycle is both faster and
safe after source-separating the release gates and enabling bounded in-shard ExUnit concurrency.
It does not measure cold full-repository build time, and it does not treat the focused
large-ingestion action as part of pull-request latency.

The comparison has two named revisions:

- **Before revision:** the instrumentation-only commit that adds the connection observer and
  dedicated `IntegrationBenchmark` BuildBuddy action. It is the direct parent of the first commit
  that changes sandbox behavior, source partitioning, test async flags, or ordinary target
  selection.
- **After revision:** the final implementation commit after rebalancing.

Both revisions therefore contain the identical benchmark harness, flags, observer, action name,
runner image, and pool. A harness hash covers the normalized action block, observer sources, and
observer Bazel rule and is emitted by the checked-in
`//:integration_benchmark_harness_hash` target. The before revision changes measurement only; its ordinary workload still
embeds both release gates and runs with `max_cases: 1`. The exact full SHAs and a hash of the action
block are recorded before any cohort is accepted.

The dedicated action runs only when explicitly requested for the selected commit and never uses a
pull-request merge checkout. Each invocation asserts that its effective `git rev-parse HEAD` equals
the requested commit. The evidence records requested SHA, base SHA (if BuildBuddy reports one), and
effective HEAD so a synthetic merge can never be mislabeled as either cohort.

## Controlled run protocol

Before recording either cohort:

1. Complete `bazel build -c opt --config=ci --//build:enable_integration_tests //...` for the exact
   source revision and configuration under test.
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
  "env": {"SERVICERADAR_BENCHMARK_EXPECTED_SHA": "${BENCHMARK_SHA}"},
  "disable_retry": true
}
JSON
```

`BUILDBUDDY_API_KEY` and `BENCHMARK_SHA` must already be set; the request is never run with shell
tracing. The returned invocation id/URL is recorded before the next sequential attempt starts.

Each attempt uses a fresh run id and the production lifecycle:

```text
sweep -> prepare/current check -> provision -> ordinary integration wildcard -> teardown
```

The clock starts immediately before
`bazel run ... //:buildbuddy_setup_fixture_env` and stops after the matching
`//rust/integration-db:teardown_db` attempt returns, whether it succeeds or fails. Docker
authentication, the full build, and template migration are outside the clock. Fixture
configuration materialization, sweep, the current-template check, provisioning, all ordinary
integration targets, and outcome-bearing teardown are inside it. A failed teardown makes the row a
failure and its duration censored: it remains in the attempt log but is excluded from latency
statistics because the required lifecycle endpoint was not reached successfully.

The common measurement flags are:

```text
-c opt
--config=ci
--strategy=TestRunner=local
--//build:enable_integration_tests
--//build:run_id=<fresh-run-id>
--flaky_test_attempts=1
--test_output=all
--test_env=SERVICERADAR_TEST_SLOWEST=15
```

Both revisions use the same benchmark target selection:

```text
--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test
```

The negative Bazel tag changes nothing at the before revision because no target has that tag and
both release gates are still compiled into ordinary integration shards. At the after revision it
excludes the new dedicated target. The measured product outcome is ordinary pull-request latency;
the gain combines gate extraction, bounded concurrency, and rebalancing and must not be described
as a pure transaction-concurrency microbenchmark.

## Metrics and calculations

Every attempt records:

- requested source SHA, effective HEAD, reported base SHA, benchmark-action hash, BuildBuddy
  invocation URL, run id, runner image, pool, and UTC start/end;
- lifecycle seconds from the clock boundary above;
- TestRunner duration for each of
  `//elixir/serviceradar_core:integration_tests_s0` through `integration_tests_s7`;
- each shard's 15 slowest ExUnit cases from `SERVICERADAR_TEST_SLOWEST` output;
- maximum sampled run-scoped and fixture-wide PostgreSQL connections, with sample interval,
  observer-session exclusion count, and observer UTC sample-window start/end;
- live `max_connections`, `superuser_reserved_connections`, optional `reserved_connections`, and
  derived usable client slots;
- suite result, observer result, teardown result, Bazel retry count, workflow retry count,
  effective-HEAD assertion, and failure classification.

The checked-in Bazel-owned connection observer samples `pg_stat_activity` every 500 milliseconds.
Run-scoped connections are sessions whose database name begins with the guarded run's disposable
database prefix. Because the prefix contains `_`, the query uses literal prefix comparison such as
`left(datname, char_length($1)) = $1`; it MUST NOT use an unescaped SQL `LIKE` pattern. Fixture-wide
connections are all non-background sessions on the fixture. The observer starts after fixture
configuration is materialized and before provisioning, waits for a bounded ready handshake before
the lifecycle continues, and stops after teardown. Ready/suite/quiescent/stop paths are initially
absent children of one private temporary directory; they are never pre-created with `mktemp`.
Its one administrator session is emitted as
`observer_sessions_excluded: 1` and excluded by backend PID from both sampled counts. The summary
also emits UTC epoch-millisecond `sample_window_start_ms` and `sample_window_end_ms`. The metric is
explicitly a maximum sampled value, not a claim that a 500 ms poll observes every sub-interval
spike. It also queries the live capacity settings rather than assuming the committed CNPG manifest
is the server currently under test.

After the suite exits, the action writes its suite-complete marker and waits for the observer's
quiescent marker before teardown starts. The observer writes that marker only after zero run-scoped
client connections for two consecutive samples. That is the executable leaked database-process check:
Repo pools and their test-owned children must be gone when each BEAM exits. Non-database BEAM
processes cannot survive the TestRunner VM boundary. Teardown then verifies that no database under
the run prefix remains.

Statistics use the raw values without trimming outliers:

- median is the average of ordered values 10 and 11;
- nearest-rank p95 is ordered value 19 of 20;
- per-attempt shard skew is `max(duration) / min(non-empty duration)`;
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
| Stability | 20 consecutive before and 20 consecutive after attempts pass with no Bazel or workflow retries |
| Isolation | Zero sandbox ownership errors or cross-owner visibility failures |
| Database locking | Zero PostgreSQL deadlocks |
| Cleanup | Two consecutive zero run-scoped samples before teardown and zero disposable databases after teardown |
| Balance | Every after attempt has shard skew at most 1.5 |
| Topology | Exactly eight ordinary shards; Repo pool sizes unchanged |
| Run-scoped connections | Peak at most 144, preserving capacity above eight 16-connection pools |
| Fixture-wide connections | Maximum sampled value at most `floor(live usable client slots * 0.90)` |
| Heavy coverage | Both source-separated release-gate suites pass in the focused lifecycle |

The non-gating improvement target is at least 35% lower p95; the report always includes before/after
median, p95, and relative delta. If the absolute bound passes but the improvement target does not,
the evidence explains the variance before merge. The 90-second absolute bound and every row in the
table above are release criteria. Any safety threshold failure stops rollout; the cap returns to one
or the offending module returns to the serial lane before the cohort restarts.

## Evidence record

Historical observations motivated the work but are not the controlled before cohort. Five recent
successful pull-request integration phases ranged from 141 to 262 seconds. A separately inspected
2026-08-23 run lasted approximately 183.4 seconds across fixture materialization through teardown;
its shard durations were 107.8, 147.3, 62.3, 77.0, 58.1, 69.1, 68.1, and 59.2 seconds. That run is
available at
<https://carverauto.buildbuddy.io/invocation/6b474999-9800-4806-9af7-52fd70a352c6>.

These values are context only because they come from different revisions and were not executed as
one controlled cohort. Authoritative evidence first records cohort metadata:

| Cohort | Requested SHA | Effective HEAD | Reported base SHA | Harness hash | Runner image | Pool | Sample ms | Observer sessions excluded | Max connections | Superuser reserved | General reserved | Usable slots |
| --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |

Every started attempt then uses this schema. The invocation contains the slowest-case output and
observer window; the summary columns keep every threshold independently recomputable:

| Cohort | Attempt | Invocation | Run id | UTC start | UTC end | Observer UTC start | Observer UTC end | Lifecycle s / censored | s0 | s1 | s2 | s3 | s4 | s5 | s6 | s7 | Skew | Run sampled peak | Fixture sampled peak | Pre-teardown zero samples | Bazel retries | Workflow retries | Suite | Observer | Teardown | Classification |
| --- | ---: | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |

The completed change appends every attempt row, including failed sequences, followed by the
accepted 20-row before/after medians, p95 values, relative delta, maximum skew, sampled connection
peaks, and acceptance decision.
