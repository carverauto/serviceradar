## ADDED Requirements

### Requirement: Core integration tests support transaction-isolated module concurrency
The core integration suite SHALL allow explicitly audited `ServiceRadar.DataCase` modules to run
concurrently inside each Bazel shard. Every concurrent database/DataCase test SHALL own a distinct
rollback-only Ecto SQL Sandbox transaction, and ending one test MUST NOT change global sandbox mode,
check in another test's connection, or make its uncommitted rows visible to another owner. Every selected DataCase
module SHALL have exactly one checked-in disposition: async-eligible or serial quarantine with a
concrete shared-state blocker. The disposition inventory MUST cover every ordinary selected ExUnit
module, including non-DataCase modules, plus every source with no selected module, so placement uses
the actual module-level scheduling jobs. A transaction-isolated DataCase module MUST be promoted
rather than left serial by default.

An async non-DataCase module MUST provide positive evidence that it performs no direct or indirect
unowned Repo work and has no VM-global or external shared-state blocker, or it MUST use an explicit
audited owner contract equivalent to the DataCase isolation guarantees.

#### Scenario: Async non-DataCase module has positive safety evidence
- **GIVEN** a selected non-DataCase module is classified async
- **WHEN** its disposition is audited
- **THEN** evidence SHALL prove it performs no direct or indirect unowned Repo work, or identify its
  explicit isolated owner contract
- **AND** evidence SHALL prove it has no VM-global or external shared-state blocker

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

#### Scenario: Eligible module is promoted
- **GIVEN** an ordinary DataCase module keeps all database work in its rollback-only owner
- **AND** it has no database-global, VM-global, external-resource, or unmanaged-process blocker
- **WHEN** the disposition inventory is validated
- **THEN** the module SHALL declare `async: true`
- **AND** it SHALL be included in the checked-in async allowlist

#### Scenario: Mixed module is split
- **GIVEN** an ordinary DataCase source contains transaction-isolated cases and a separable unsafe
  race, global-state assertion, or external-resource case
- **WHEN** async eligibility is implemented
- **THEN** the transaction-isolated cases SHALL move to an async module or source
- **AND** only the unsafe cases SHALL remain in a serial quarantine

#### Scenario: Every serial module has evidence
- **GIVEN** an ordinary DataCase module remains `async: false`
- **WHEN** the disposition contract is checked
- **THEN** the serial-quarantine inventory SHALL name its concrete operation, resource, or call
  chain and required scope
- **AND** a reason token without matching audit evidence SHALL fail the contract
- **AND** absence from both disposition sets SHALL fail the contract

#### Scenario: Source-level mode is homogeneous
- **GIVEN** an ordinary selected source contains both async and serial ExUnit modules
- **WHEN** the source disposition and topology contracts are checked
- **THEN** the contract SHALL fail until the modules are split into distinct sources
- **AND** each selected module in the resulting sources SHALL appear exactly once with its actual
  execution mode

#### Scenario: Multiple async modules remain separate scheduling jobs
- **GIVEN** one retained source contains two selected async ExUnit modules
- **WHEN** its predicted shard load is calculated
- **THEN** both modules SHALL appear as distinct indivisible async jobs with their own weights
- **AND** the source-load weight SHALL be added only once for their shared file

#### Scenario: Unit-only files are not loaded by integration shards
- **GIVEN** the complete ordinary test-source glob and the integration runner's exact tag filters
- **WHEN** a source contributes no selected `:integration` or `:requires_app` case
- **THEN** its disposition SHALL be `load_only`
- **AND** it SHALL remain available to unit targets but SHALL NOT appear in an ordinary integration
  shard

#### Scenario: Source pruning preserves selected test identities
- **GIVEN** an all-source control and the pruned ordinary integration source union
- **WHEN** both enumerate tests under identical integration include/exclude rules
- **THEN** their selected test-identity sets SHALL be exactly equal
- **AND** any missing or additional selected identity SHALL fail before production source pruning

### Requirement: Suite startup configuration is concurrency-neutral
The integration runner SHALL configure VM-global test behavior exactly once before ExUnit schedules
modules. A no-option or idempotent module-level `TestSupport.start_core!` call MUST NOT mutate
Application configuration, and async-eligible modules MUST NOT perform redundant suite startup in
`setup_all`.

#### Scenario: Runner configures synchronous audit writes once
- **GIVEN** a database-backed integration suite is starting
- **WHEN** `test_helper.exs` starts the core application before scheduling tests
- **THEN** it SHALL explicitly establish the synchronous audit-writer test setting
- **AND** it SHALL establish manual Sandbox mode before owners are created

#### Scenario: Idempotent startup preserves global configuration
- **GIVEN** the core application is already running and the audit-writer setting has a known value
- **WHEN** `start_core!` is called without an explicit synchronous-audit option
- **THEN** the setting SHALL remain unchanged
- **AND** the call SHALL only ensure required applications and the Repo are running

#### Scenario: Async module mutates startup configuration
- **GIVEN** a candidate async module calls startup with a global-configuration option or mutates
  Application configuration in module setup
- **WHEN** the async disposition contract runs
- **THEN** the candidate SHALL fail eligibility
- **AND** it SHALL remain serial until the mutation moves to suite bootstrap or becomes test-local

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
configuration, Oban-wide operations, fixed registries or PubSub topics, unfiltered global telemetry
or logger handlers, global ETS/cache clears, unmanaged children, globally named/application-
supervised processes, or behavior requiring independent real database connections MUST remain
`async: false` within their shard and SHALL have a checked-in quarantine reason. Modules that use a fixed
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

#### Scenario: Global identifier becomes test-local
- **GIVEN** a quarantined module uses a fixed registry key, PubSub topic, telemetry handler, cache
  key, or similar VM-global identifier
- **WHEN** the identifier is made unique per test and cleanup targets only that exact identifier
- **THEN** the module MAY be re-audited for async eligibility
- **AND** a whole-table, whole-registry, or unfiltered negative assertion SHALL still require the
  serial lane

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
SHALL validate the expanded async set at two concurrently scheduled modules before advancing all
eight shards to a final cap of four. The shard count, Repo pool size of 12, and fixture database
connection ceiling MUST NOT be increased as part of this rollout.

#### Scenario: Cap-two migration safety wave passes
- **GIVEN** the broad async disposition is implemented and all eight shard databases are fresh
- **WHEN** one complete ordinary wave runs at `max_cases: 2` with trace off, timeouts enabled,
  retries disabled, and the connection observer active
- **THEN** all shards SHALL pass without ownership errors, deadlocks, checkout drops, leaked
  processes, or database residue
- **AND** the observed connection peaks SHALL remain within the acceptance bounds

#### Scenario: Cap-four treatment advances safely
- **GIVEN** the cap-two migration safety wave has passed
- **WHEN** all eight ordinary shards advance together to `max_cases: 4`
- **THEN** Repo pool sizes and fixture capacity SHALL remain unchanged
- **AND** the complete observed safety wave SHALL be repeated without retries
- **AND** any failure SHALL return the responsible module or resource to audit rather than being
  hidden by retries, a larger pool, or a relaxed timeout

#### Scenario: Ordinary pull request runs bounded parallelism
- **GIVEN** the guarded fixture lifecycle has provisioned databases `s0` through `s7`
- **WHEN** BuildBuddy runs the ordinary core integration suite
- **THEN** the eight Bazel shard targets SHALL remain eligible to execute in parallel
- **AND** every final-treatment shard SHALL receive integration `max_cases` equal to 4
- **AND** serial modules SHALL retain ExUnit's non-overlap barrier within their shard
- **AND** the designated shared-external-resource lane SHALL remain within `s7`

#### Scenario: Invalid concurrency configuration fails
- **GIVEN** an integration shard receives a missing, malformed, zero, negative, or above-pool
  concurrency value
- **WHEN** `test_helper.exs` configures ExUnit
- **THEN** the shard SHALL fail before executing integration tests
- **AND** it SHALL NOT silently use the machine scheduler count

#### Scenario: Ordinary provisioning retains eight databases
- **WHEN** the ordinary core lifecycle invokes `provision_db`
- **THEN** it SHALL clone exactly the `s0` through `s7` databases for that run
- **AND** it SHALL NOT clone the large-ingestion database
- **AND** all database-facing test actions SHALL retain local, non-cached execution

### Requirement: Workflow CPU and Repo capacity are controlled independently
Ordinary integration targets SHALL explicitly pin the test Repo pool size to 12. Before the final
cohorts, workflow CPU allocation SHALL be selected through a same-revision 2-CPU versus 12-CPU
diagnostic so scheduler capacity cannot silently change database capacity or be conflated with test
topology.

#### Scenario: CPU allocation diagnostic changes one factor
- **GIVEN** the final eight-shard source placement and cap-four treatment
- **WHEN** five attempts per arm alternate explicit 2-CPU and 12-CPU diagnostics
- **THEN** both arms SHALL run the complete ordinary pull-request integration wildcard
- **AND** both arms SHALL use Repo pool size 12 and otherwise identical lifecycle and test flags
- **AND** each runner SHALL report scheduler count, effective Repo pool size, topology, lane, cap,
  trace mode, and timeout mode
- **AND** the diagnostic rows SHALL NOT enter the 20-run acceptance cohorts

#### Scenario: CPU winner uses a pre-registered rule
- **GIVEN** five completed attempts for each CPU arm
- **WHEN** the CPU request is selected
- **THEN** an arm SHALL be selectable only when all five attempts pass every safety and
  connection-headroom gate
- **AND** rollout SHALL stop if neither arm is selectable
- **AND** the sole selectable arm SHALL win when the other arm is unsafe
- **AND** when both are selectable, 12 CPUs SHALL win only if its untrimmed median lifecycle is at
  least 10% lower; otherwise 2 CPUs SHALL win

#### Scenario: Accepted cohorts use one explicit CPU size
- **GIVEN** the CPU diagnostic has selected a safety-clean allocation by the pre-registered rule
- **WHEN** the before and after authoritative cohorts run
- **THEN** both revisions SHALL request that same explicit CPU allocation
- **AND** the production `BazelCI` action SHALL request that allocation
- **AND** both SHALL retain Repo pool size 12
- **AND** a CPU or pool-size difference SHALL invalidate cohort comparability

#### Scenario: CPU evidence survives only identical diagnostic inputs
- **GIVEN** CPU diagnostics ran before corrected before/after lineage was rewritten
- **WHEN** the frozen after SHA is selected
- **THEN** CPU evidence MAY carry forward only if both SHAs have the same checked-in diagnostic
  input hash covering ordinary sources, runtime/build inputs, observer/lifecycle, runner
  image/pool, and normalized CPU2/CPU12 actions
- **AND** both SHA/hash tuples SHALL be recorded
- **AND** a hash difference SHALL require all ten CPU attempts to rerun after the frozen after SHA
  is published and before any runner-layout attempt

### Requirement: Shard placement models source load plus serial and async execution
Final ordinary source placement SHALL distinguish common retained-source load, async module
weights, and serial module weights. For each shard, relative predicted load SHALL equal retained
source count times the common source-load weight plus the sum of serial module weights plus the
deterministic list-scheduling makespan of async module weights at the final cap of four.
Trace-derived weights MUST remain relative within one measurement mode and MUST NOT be converted to
wall-time forecasts. A sum-only source-weight partition MUST NOT be accepted as the final placement
model.

#### Scenario: Concurrency-aware placement is deterministic
- **GIVEN** measured module weights and complete source/module dispositions
- **WHEN** ordinary sources are partitioned repeatedly in different input orders
- **THEN** every source SHALL appear in exactly one shard
- **AND** the resulting partitions and predicted loads SHALL be identical
- **AND** source count and shard name SHALL provide stable tie-breakers

#### Scenario: Serial and async weights contribute differently
- **GIVEN** one shard candidate contains serial and async sources
- **WHEN** its predicted load is calculated
- **THEN** one common source-load weight SHALL be added per retained source
- **AND** all serial module weights SHALL be summed
- **AND** each async module SHALL remain an indivisible job scheduled onto one of four virtual slots
- **AND** only the maximum async slot load SHALL be added to the serial sum

#### Scenario: Fixed external sources remain pinned
- **GIVEN** concurrency-aware placement is enabled
- **WHEN** sources with audited mutable fixture-global names or cross-BEAM collision behavior are
  assigned
- **THEN** those sources SHALL preseed designated shard `s7`
- **AND** no optimization SHALL move them to another shard or classify them async
- **AND** legacy list membership or read-only external access alone SHALL NOT qualify a source as
  `fixed_external`

### Requirement: Alternative runner layouts are measured separately
Alternative runner-layout diagnostics SHALL measure one-, four-, and eight-BEAM ordinary layouts
at caps eight, seven, and four respectively, plus a five-BEAM hybrid with two async lanes at cap seven
and three serial lanes at cap one. Every arm MUST use the same source revision and source selection
with trace disabled, timeouts enabled,
retries disabled, a current template, and fresh disposable databases. Diagnostic topology rows
MUST NOT enter the authoritative 20-run before/after cohorts.

The diagnostic SHALL be treated as a comparison of pre-registered deployable bundles. Because
BEAM count, per-BEAM cap, and aggregate Repo-pool capacity differ, results MUST NOT be attributed to
BEAM count alone.

#### Scenario: Topology caps are frozen before measurement
- **GIVEN** the topology diagnostic contract is checked in
- **WHEN** the five attempts per arm begin
- **THEN** the one/four/eight/hybrid caps SHALL remain 8/7/4/(7 async, 1 serial)
- **AND** no cap SHALL be tuned in response to an observed diagnostic result

#### Scenario: Diagnostics vary only the core topology
- **GIVEN** the one-, four-, eight-, and hybrid diagnostic arms
- **WHEN** target selection and build warmth are validated
- **THEN** each arm's core source union SHALL equal the production eight-shard core source union
- **AND** every arm SHALL append the same checked-in SRQL and other non-core integration targets
- **AND** that non-core list SHALL equal exactly the production pull-request wildcard's ordinary
  target set minus the production core labels and excluded heavy target
- **AND** each diagnostic arm SHALL replace only the production core labels with its diagnostic
  core labels
- **AND** each diagnostic arm's core source and selected-test identity union SHALL equal the
  production eight-shard core workload
- **AND** every selected core label, whether manual or production-eight, SHALL be explicitly built
  with the measured configuration before the lifecycle clock starts
- **AND** the authoritative benchmark SHALL retain the pull-request wildcard and reject a topology
  selector
- **AND** the diagnostic action SHALL require an expected source SHA and fail before provisioning
  when effective HEAD differs

#### Scenario: One-BEAM hypothesis is falsified or supported by evidence
- **GIVEN** the broad async source set and unchanged Repo pool size of 12
- **WHEN** five no-overlap one-BEAM diagnostic attempts run at the frozen cap of eight across the
  rotated rounds
- **THEN** lifecycle time, runner configuration, connection peak, failures, and residue SHALL be
  recorded
- **AND** all five attempts SHALL report zero per-Repo checkout drops or starvation
- **AND** the result SHALL be compared with five four-BEAM, five final eight-BEAM, and five hybrid
  attempts

#### Scenario: Hybrid topology keeps source ownership explicit
- **GIVEN** the five-BEAM hybrid diagnostic
- **WHEN** its source sets and concurrency caps are validated
- **THEN** two lanes SHALL contain every async source exactly once and run at cap seven
- **AND** three lanes SHALL contain every serial source exactly once and run at cap one
- **AND** the async and serial source sets SHALL be disjoint and exhaustive across ordinary sources

#### Scenario: Fixed external resources remain co-located in every multi-BEAM arm
- **GIVEN** a four-, eight-, or hybrid-BEAM diagnostic arm
- **WHEN** its source placement is validated
- **THEN** every `fixed_external` source SHALL appear in exactly one designated serial lane
- **AND** no `fixed_external` source SHALL appear in any other lane

#### Scenario: Challenger placement uses its frozen execution model
- **GIVEN** four-BEAM and hybrid source placement is generated
- **WHEN** placement contracts run with reversed and shuffled source input
- **THEN** the four-BEAM arm SHALL use the module-level execution model at cap seven
- **AND** hybrid async lanes SHALL balance cap-seven async module makespan
- **AND** hybrid serial lanes SHALL balance source load plus serial-module sums after the designated
  fixed-external lane is preseeded
- **AND** membership and predicted relative loads SHALL remain deterministic

#### Scenario: Layout attempt order controls time drift
- **GIVEN** five attempts are required for each runner layout
- **WHEN** the diagnostic screen runs
- **THEN** it SHALL run five non-overlapping rounds containing every arm once
- **AND** arm order SHALL rotate by one position in each successive round

#### Scenario: Smaller topology cannot silently replace eight shards
- **GIVEN** a smaller or hybrid topology appears faster
- **WHEN** production topology is selected
- **THEN** the five-run screen SHALL show at least 10% lower median lifecycle time
- **AND** it SHALL pass every five-run isolation, headroom, and cleanup gate
- **AND** adopting it SHALL require an explicit amendment to this proposal followed by the full
  amended 20-run retry-free acceptance contract
- **AND** medians SHALL NOT be compared unless all five eight-BEAM reference attempts and all five
  challenger attempts are safety-clean; otherwise the full screen SHALL restart after correction

### Requirement: Heavy release qualification is source-separated from pull-request tests
Both large-ingestion release-gate suites and the intact two-pass cold database-bootstrap test SHALL
be source-separated from pull-request tests.
The 50,000-device router ingestion test and the 500-device, three-round identifier-cardinality
gate SHALL live in a Bazel source set that is disjoint from ordinary unit and integration test
source sets. The cold bootstrap source SHALL also be explicitly disjoint from all eight ordinary
shards while retaining both production startup invocations and their assertions. All three SHALL
run through the explicit
`large_ingestion_release_gate` target against a dedicated disposable database. ExUnit tag
include/exclude precedence MUST NOT be able to select the heavy source from an ordinary
pull-request shard, and the pull-request integration wildcard MUST exclude the dedicated target's
`large_ingestion_test` Bazel tag.

#### Scenario: Ordinary integration include cannot select the heavy test
- **GIVEN** the ordinary integration runner positively includes `:integration` and
  `:requires_app`
- **WHEN** Bazel constructs the eight shard source sets
- **THEN** none of those source sets SHALL contain a large-ingestion release-gate file
- **AND** none SHALL contain the cold database-bootstrap source
- **AND** the pull-request integration wildcard SHALL filter out the dedicated target with
  `-large_ingestion_test`
- **AND** neither release-gate suite SHALL execute in the pull-request action
- **AND** the cold database-bootstrap suite SHALL NOT execute in the pull-request action

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
- **AND** the target SHALL run the two ingestion suites and cold bootstrap serially

#### Scenario: Cold bootstrap coverage is moved intact
- **GIVEN** cold bootstrap applies the production baseline and migration history on its first pass
- **AND** its second pass covers the normal migrated restart and idempotence
- **WHEN** the test is source-separated from ordinary pull-request shards
- **THEN** both startup invocations and all assertions SHALL remain unchanged
- **AND** the heavy lifecycle SHALL verify exact scratch-database cleanup or its existing stale
  sweep backstop

#### Scenario: CI cannot lower the release workload
- **WHEN** the BuildBuddy heavy-gate action executes
- **THEN** the router test SHALL ingest 50,000 devices
- **AND** the cardinality test SHALL ingest 500 devices across three rounds
- **AND** a developer-only diagnostic override MUST NOT lower either CI workload

### Requirement: Heavy coverage is a default-branch and release qualification gate
BuildBuddy SHALL run the focused heavy lifecycle on pushes to `staging`, on a nightly UTC
schedule, and for release tags. BuildBuddy's linked GitHub App SHALL publish the classic commit
status context `LargeIngestionGate` for the exact commit, and release publication MUST wait for a
successful BuildBuddy result for the immutable tag commit.

#### Scenario: Nightly coverage runs outside pull requests
- **GIVEN** the latest default-branch commit
- **WHEN** the nightly BuildBuddy schedule fires
- **THEN** it SHALL run only the focused heavy database lifecycle and target
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
- **AND** it SHALL NOT run the source-separated heavy release-qualification target

### Requirement: Parallel integration acceptance is measured and retry-free
Before bounded concurrency is considered complete, the implementation SHALL pass at least 20
consecutive CI-equivalent ordinary integration lifecycles with test retries disabled. Measurement
SHALL start before fixture configuration materialization and end after successful teardown, with a
current template and the exact Bazel configuration already built. The end timestamp SHALL be
captured immediately when teardown returns, before observer shutdown/wait overhead. It SHALL
include all targets selected by the ordinary pull-request integration filter and exclude only the
`large_ingestion_test`-tagged heavy release-qualification target. Across that run set, nearest-rank
p95 SHALL be at most 90 seconds, and relative p95 improvement versus the controlled before cohort
SHALL be at least 50%. Whether relative improvement reaches the 60% stretch target SHALL be
reported. The slowest non-empty shard
SHALL be no more than 1.5 times the fastest, and there SHALL be no sandbox ownership error,
deadlock, leaked test process, leaked disposable database, or retry-masked failure.

The controlled comparison SHALL use the instrumentation-only commit immediately before the first
behavior change as `before`, the final rebalanced implementation as `after`, and one identical
non-merging benchmark harness at both revisions. Both accepted cohorts SHALL contain 20 consecutive
successful, retry-free lifecycle attempts and SHALL retain all failed sequence rows. Authoritative
timed and gating actions SHALL NOT enable ExUnit's built-in slowest reporting because it forces
trace, serial execution, and infinite test timeouts. Each ordinary shard SHALL instead emit an
effective-runner marker showing the declared `max_cases`, trace mode, and timeout mode.

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
- **AND** relative p95 improvement versus the accepted before cohort SHALL be at least 50%
- **AND** the report SHALL state whether BuildBuddy relative improvement reached the 60% stretch
  target
- **AND** slowest/fastest non-empty shard skew SHALL be at most 1.5
- **AND** the result SHALL be achieved with eight shards and unchanged Repo pool sizes

#### Scenario: Before and after cohorts are comparable
- **GIVEN** the instrumentation-only before commit is the direct parent of the first behavior change
- **WHEN** BuildBuddy executes alternating before/after attempts
- **THEN** each request SHALL name and verify the exact source SHA without a synthetic merge
- **AND** the normalized benchmark action, observer sources, observer Bazel rule, runner image,
  workflow pool, explicit CPU allocation, Repo pool size 12, flags, and target selection SHALL be
  identical
- **AND** the before shards SHALL report `max_cases: 1`, the intermediate safety wave SHALL report
  `max_cases: 2`, and the final after shards SHALL report `max_cases: 4`
- **AND** all authoritative cohort shards SHALL report trace disabled and timeouts enabled
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
