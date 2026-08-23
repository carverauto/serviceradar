## ADDED Requirements

### Requirement: Core integration tests support transaction-isolated module concurrency
The core integration suite SHALL allow explicitly audited `ServiceRadar.DataCase` modules to run
concurrently inside each Bazel shard. Every concurrent test SHALL own a distinct rollback-only Ecto
SQL Sandbox transaction, and ending one test MUST NOT change global sandbox mode, check in another
test's connection, or make its uncommitted rows visible to another owner.

#### Scenario: Concurrent owners isolate writes
- **GIVEN** two async DataCase tests are scheduled in the same shard
- **WHEN** each test inserts data through its own sandbox owner
- **THEN** each test SHALL see its own uncommitted data
- **AND** neither test SHALL see the other owner's uncommitted data
- **AND** stopping either owner SHALL roll back only that owner's changes

#### Scenario: One async test finishes while another is querying
- **GIVEN** two non-shared sandbox owners are active
- **WHEN** the first test completes and its owner is stopped
- **THEN** teardown SHALL NOT call `Sandbox.mode/2`
- **AND** the second test SHALL retain its checked-out connection and continue querying

### Requirement: Test-owned collaborating processes use explicit sandbox routing
The core test support API SHALL provide a project-owned way to grant a test-owned child process
access to the calling test's sandbox transaction. Concurrent tests MUST NOT use Repo shared mode as
a substitute for explicit routing, and a globally named or application-supervised process MUST NOT
be granted to multiple concurrent owners.

#### Scenario: Allowed child observes the parent's transaction
- **GIVEN** an async DataCase test starts a child process whose lifetime is supervised by that test
- **WHEN** the test explicitly allows the child through the project-owned sandbox helper
- **THEN** the child SHALL query through the parent's sandbox connection
- **AND** it SHALL observe the parent's uncommitted writes
- **AND** it SHALL stop before the owner is released

#### Scenario: Unrelated owner remains isolated
- **GIVEN** a child process is allowed by one async test owner
- **WHEN** a second async owner queries the same logical records
- **THEN** the second owner SHALL NOT inherit the allowance
- **AND** it SHALL NOT observe the first owner's uncommitted writes

### Requirement: Unsafe integration tests use the serial scope matching their shared state
Affected integration modules SHALL use the serial scope matching their shared state. Modules that
use unboxed transactions, DDL, `TRUNCATE`, materialized-view refresh, application-global
configuration, globally named/application-supervised processes, or behavior requiring independent
real database connections MUST remain `async: false` within their shard. Modules that use a fixed
NATS or other fixture-global resource name MUST additionally be pinned to one designated existing
outer shard and absent from the other seven, unless an audited per-test namespace and scoped
cleanup make the external state independent. Test support MUST reject `async: true` combined with
`sandbox: :unboxed` before it changes Repo pool mode.

#### Scenario: Async unboxed test fails closed
- **GIVEN** a DataCase module is declared `async: true`
- **AND** a test requests `sandbox: :unboxed`
- **WHEN** DataCase setup begins
- **THEN** setup SHALL fail with an isolation-classification error
- **AND** it SHALL NOT switch the Repo to automatic mode
- **AND** the message SHALL direct the test to the serial lane

#### Scenario: Serial shared owner retains global cleanup
- **GIVEN** a serial DataCase test uses shared ownership for application processes
- **WHEN** the test completes
- **THEN** the existing application-task drains SHALL finish before owner release
- **AND** the owner SHALL be stopped
- **AND** the Repo SHALL be restored to manual sandbox mode

#### Scenario: Async caller requests the shared-owner helper
- **GIVEN** `with_repo_owner(context, fun)` receives a context with `async: true`
- **WHEN** it validates the requested owner mode
- **THEN** it SHALL reject the call before starting a shared owner
- **AND** it SHALL NOT change Repo pool mode

#### Scenario: Global-process test is reviewed for async conversion
- **GIVEN** an integration test invokes a globally named or application-supervised process that
  performs Repo work
- **WHEN** async eligibility is evaluated
- **THEN** the module SHALL remain serial unless the process is replaced by a test-owned instance
- **AND** one global process SHALL NOT be allowed to two concurrent sandbox owners

#### Scenario: Fixed external resource is serialized across BEAMs
- **GIVEN** integration modules share a fixed NATS stream, subject, or other fixture-global name
- **WHEN** Bazel partitions the ordinary integration sources
- **THEN** every such module SHALL be assigned to the designated `s7` shard
- **AND** every such module SHALL remain `async: false`
- **AND** no source in `s0` through `s6` SHALL use that fixed resource

#### Scenario: Unique external namespace is reviewed as independent
- **GIVEN** an integration module derives its external resource name from the test or guarded run id
- **AND** cleanup is scoped to that exact resource
- **WHEN** the module is evaluated for a non-designated shard
- **THEN** the audit SHALL record the uniqueness and cleanup evidence
- **AND** Ecto transaction isolation alone SHALL NOT be accepted as that evidence

### Requirement: Core integration parallelism is bounded at both levels
The ordinary core integration suite SHALL retain eight independently provisioned Bazel shards and
SHALL initially limit each shard to two concurrently scheduled async ExUnit modules. The shard
count, Repo pool sizes, and fixture database connection ceiling MUST NOT be increased as part of
the initial rollout.

#### Scenario: Ordinary pull request runs bounded parallelism
- **GIVEN** the guarded fixture lifecycle has provisioned databases `s0` through `s7`
- **WHEN** BuildBuddy runs the ordinary core integration suite
- **THEN** the eight Bazel shard targets SHALL remain eligible to execute in parallel
- **AND** every shard SHALL receive integration `max_cases` equal to 2
- **AND** serial modules SHALL retain ExUnit's non-overlap barrier within their shard
- **AND** the designated shared-external-resource lane SHALL remain within `s7`

#### Scenario: Invalid concurrency configuration fails
- **GIVEN** an integration shard receives a missing, malformed, zero, or negative concurrency value
- **WHEN** `test_helper.exs` configures ExUnit
- **THEN** the shard SHALL fail before executing integration tests
- **AND** it SHALL NOT silently use the machine scheduler count

#### Scenario: Ordinary provisioning retains eight databases
- **WHEN** the ordinary core lifecycle invokes `provision_db`
- **THEN** it SHALL clone exactly the `s0` through `s7` databases for that run
- **AND** it SHALL NOT clone the large-ingestion database
- **AND** all database-facing test actions SHALL retain local, non-cached execution

### Requirement: Large-ingestion coverage is source-separated from pull-request tests
Both large-ingestion release-gate suites SHALL be source-separated from pull-request tests.
The 50,000-device router ingestion test and the 500-device, three-round identifier-cardinality
gate SHALL live in a Bazel source set that is disjoint from ordinary unit and integration test
source sets. They SHALL run through an explicit
`large_ingestion_release_gate` target against a dedicated disposable database. ExUnit tag
include/exclude precedence MUST NOT be able to select the heavy source from an ordinary
pull-request shard, and the pull-request integration wildcard MUST exclude the dedicated target's
`large_ingestion_test` Bazel tag.

#### Scenario: Ordinary integration include cannot select the heavy test
- **GIVEN** the ordinary integration runner positively includes `:integration` and
  `:requires_app`
- **WHEN** Bazel constructs the eight shard source sets
- **THEN** none of those source sets SHALL contain a large-ingestion release-gate file
- **AND** the pull-request integration wildcard SHALL filter out the dedicated target with
  `-large_ingestion_test`
- **AND** neither release-gate suite SHALL execute in the pull-request action

#### Scenario: Focused heavy target uses a dedicated database
- **GIVEN** one guarded run id and a current template
- **WHEN** `provision_db_large_ingestion` and `large_ingestion_release_gate` run
- **THEN** both targets SHALL derive the same `<run>_large_ingestion` database name
- **AND** both targets SHALL declare the shared run-id file as data
- **AND** the Elixir target SHALL load `integration_env.exs` before its test configuration loader
- **AND** the Rust target SHALL declare the core migration filegroup and provision only the
  `large_ingestion` suffix
- **AND** ordinary `s0` through `s7` databases SHALL not be required
- **AND** teardown SHALL remove the dedicated database by the shared run prefix

#### Scenario: CI cannot lower the release workload
- **WHEN** the BuildBuddy heavy-gate action executes
- **THEN** the router test SHALL ingest 50,000 devices
- **AND** the cardinality test SHALL ingest 500 devices across three rounds
- **AND** a developer-only diagnostic override MUST NOT lower either CI workload

### Requirement: Heavy ingestion is a default-branch and release qualification gate
BuildBuddy SHALL run the focused large-ingestion lifecycle on pushes to `staging`, on a nightly UTC
schedule, and for release tags. BuildBuddy's linked GitHub App SHALL publish the classic commit
status context `LargeIngestionGate` for the exact commit, and release publication MUST wait for a
successful BuildBuddy result for the immutable tag commit.

#### Scenario: Nightly coverage runs outside pull requests
- **GIVEN** the latest default-branch commit
- **WHEN** the nightly BuildBuddy schedule fires
- **THEN** it SHALL run only the focused large-ingestion database lifecycle and target
- **AND** success or failure SHALL be recorded against that commit
- **AND** teardown failure SHALL fail an otherwise successful action

#### Scenario: Release commit lacks heavy-gate evidence
- **GIVEN** a release tag points to a commit that contains the heavy-gate target
- **AND** that commit has no successful current `LargeIngestionGate` status
- **WHEN** the release workflow reaches qualification
- **THEN** it SHALL use explicit `statuses: read` permission to query the exact commit
- **AND** it SHALL wait for the named classic status for at most 30 minutes
- **AND** it SHALL evaluate only the newest status record for the exact context
- **AND** it SHALL accept only `success` whose parsed target URL uses HTTPS, host exactly
  `carverauto.buildbuddy.io`, and a nonempty `/invocation/<id>` path
- **AND** it SHALL stop before artifact publication if the status remains missing, pending, or
  failed

#### Scenario: Historical tag predates the complete gate contract
- **GIVEN** a manual release retry selects an immutable tag commit that does not contain the
  permanent `build/ci/large_ingestion_gate_contract.v1` marker
- **AND** that release commit is a strict ancestor of the marker's first addition commit on fetched
  `origin/staging` first-parent history
- **WHEN** the release workflow evaluates heavy-gate applicability
- **THEN** it SHALL report the gate as not applicable for that historical source tree
- **AND** it SHALL preserve the existing historical recovery path
- **AND** it SHALL NOT require a status created after that historical source tree

#### Scenario: Gate contract deletion cannot become a historical bypass
- **GIVEN** the marker's first addition commit is an ancestor of an immutable release commit
- **WHEN** that release tree lacks the marker
- **THEN** release qualification SHALL fail before artifact publication
- **AND** it SHALL NOT classify the release as historical
- **AND** git ancestry errors, a missing/malformed base marker, or missing/repeated introduction
  evidence SHALL fail closed

#### Scenario: Divergent commit cannot use historical compatibility
- **GIVEN** an immutable release tree lacks the marker
- **AND** neither the release commit nor the first-parent marker-introduction commit is an ancestor
  of the other
- **WHEN** release qualification evaluates applicability
- **THEN** it SHALL fail closed before artifact publication
- **AND** it SHALL NOT infer age from timestamps or the marker's absence alone

#### Scenario: Marker-bearing release tree is internally complete
- **GIVEN** an immutable release tree contains `build/ci/large_ingestion_gate_contract.v1`
- **WHEN** release qualification evaluates that tree
- **THEN** the tree SHALL also contain the `large_ingestion_release_gate` target and
  `LargeIngestionGate` BuildBuddy action
- **AND** absence of either contract half SHALL fail before status polling or publication
- **AND** the qualifier SHALL be a tested Bazel executable invoked after Bazel setup and before
  release tooling or artifact publication

#### Scenario: Pull request does not pay the heavy-gate cost
- **GIVEN** a normal pull request to `staging`
- **WHEN** the ordinary BuildBuddy PR action runs
- **THEN** it SHALL run the eight ordinary core integration shards
- **AND** its integration target filter SHALL include `-large_ingestion_test`
- **AND** it SHALL NOT run the source-separated large-ingestion target

### Requirement: Parallel integration acceptance is measured and retry-free
Before bounded concurrency is considered complete, the implementation SHALL pass at least 20
consecutive CI-equivalent ordinary integration lifecycles with test retries disabled. Measurement
SHALL start before fixture configuration materialization and end after successful teardown, with a
current template and the exact Bazel configuration already built. The end timestamp SHALL be
captured immediately when teardown returns, before observer shutdown/wait overhead. It SHALL include all targets
selected by the ordinary pull-request integration filter and exclude only the large-ingestion
gate. Across that run set, nearest-rank p95 SHALL be at most 90 seconds, the slowest non-empty shard
SHALL be no more than 1.5 times the fastest, and there SHALL be no sandbox ownership error,
deadlock, leaked test process, leaked disposable database, or retry-masked failure.

The controlled comparison SHALL use the instrumentation-only commit immediately before the first
behavior change as `before`, the final rebalanced implementation as `after`, and one identical
non-merging benchmark harness at both revisions. Both accepted cohorts SHALL contain 20 consecutive
successful, retry-free lifecycle attempts and SHALL retain all failed sequence rows.

#### Scenario: Acceptance run set is stable
- **GIVEN** current build artifacts and a current database template
- **WHEN** 20 consecutive guarded integration lifecycles run with `--flaky_test_attempts=1`
- **THEN** every lifecycle SHALL pass without an ownership error or PostgreSQL deadlock
- **AND** every lifecycle SHALL complete outcome-bearing teardown
- **AND** no failed test SHALL be hidden by a retry

#### Scenario: Performance target is evaluated
- **GIVEN** timing data from the accepted run set
- **WHEN** the end-to-end integration lifecycle and per-shard durations are summarized
- **THEN** the ordered 19th value of 20 lifecycle durations SHALL be at most 90 seconds
- **AND** slowest/fastest non-empty shard skew SHALL be at most 1.5
- **AND** the result SHALL be achieved with eight shards and unchanged Repo pool sizes

#### Scenario: Before and after cohorts are comparable
- **GIVEN** the instrumentation-only before commit is the direct parent of the first behavior change
- **WHEN** BuildBuddy executes alternating before/after attempts
- **THEN** each request SHALL name and verify the exact source SHA without a synthetic merge
- **AND** the normalized benchmark action, observer sources, observer Bazel rule, runner image,
  pool, flags, and target selection SHALL be identical
- **AND** each accepted cohort SHALL contain 20 consecutive successful attempts with Bazel and
  workflow retries disabled
- **AND** every started failed or censored attempt SHALL remain in the evidence record

#### Scenario: Database headroom and quiescence are measured
- **GIVEN** a benchmark lifecycle has materialized fixture configuration
- **WHEN** the Bazel-owned observer becomes ready before provisioning
- **THEN** it SHALL sample every 500 milliseconds through teardown
- **AND** it SHALL use literal database-prefix comparison, exclude and report its own administrator
  session, and record the UTC sample window plus live capacity settings
- **AND** it SHALL observe two consecutive zero run-scoped samples after suite completion and before
  teardown
- **AND** every accepted after attempt SHALL have run-scoped peak at most 144
- **AND** fixture-wide peak SHALL be at most `floor(usable client slots * 0.90)`

#### Scenario: Template migration is outside accepted measurements
- **GIVEN** template preflight detects pending migrations
- **WHEN** the benchmark prepares an attempt
- **THEN** it SHALL migrate and recheck the template before the lifecycle clock starts
- **AND** the measured current-template check SHALL NOT run migration
- **AND** an in-clock pending result SHALL be retained as a non-cohort row, cleaned up, and SHALL
  NOT enter latency statistics

### Requirement: Scheduling changes preserve the guarded fixture contract
Both ordinary and heavy integration actions SHALL preserve the existing guarded lifecycle,
template migration check, unique run id, live fixture CA, hostname verification, integration-only
credential forwarding, local non-cached database `TestRunner`, and outcome-bearing teardown. The
parallelization implementation MUST consume the final fixture configuration contract and MUST NOT
restore an environment bridge retired by config-manager adoption.

#### Scenario: Concurrent ordinary suite uses the existing fixture boundary
- **WHEN** the ordinary action enables in-shard concurrency
- **THEN** it SHALL still execute
  `sweep -> prepare -> conditional migrate -> provision -> suite -> teardown`
- **AND** fixture credentials SHALL remain absent from generic remote unit-test actions
- **AND** database TLS SHALL retain live-CA and hostname verification

#### Scenario: Fixture configuration transport changes first
- **GIVEN** config-manager adoption removes the current fixture environment bridge
- **WHEN** this change is implemented or rebased
- **THEN** ordinary and heavy targets SHALL consume the replacement contract
- **AND** they SHALL NOT recreate the retired bridge
- **AND** their database naming, sandbox isolation, and scheduling semantics SHALL remain unchanged
