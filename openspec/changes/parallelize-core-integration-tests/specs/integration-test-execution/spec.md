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

### Requirement: Async sandbox owners avoid the inventory-rollup singleton lock
Every async DataCase owner SHALL set the existing `platform.skip_inventory_rollup` PostgreSQL
setting locally for its rollback-only transaction before test work begins. The setting MUST NOT be
session-global, clone-global, or applied to a serial owner. Tests that assert the cached inventory
rollup projection SHALL remain serial with the real trigger enabled.

#### Scenario: Async owner bypasses projection-only trigger work
- **GIVEN** an async DataCase owner has started its rollback-only transaction
- **WHEN** test setup configures transaction-local database behavior
- **THEN** `platform.skip_inventory_rollup` SHALL equal `on` on that owner connection
- **AND** an explicitly allowed child SHALL observe the same setting
- **AND** an `ocsf_devices` mutation SHALL NOT update inventory count projection rows

#### Scenario: Rollup bypass cannot leak into serial coverage
- **GIVEN** an async owner with the rollup bypass ends
- **WHEN** a fresh serial/shared owner starts
- **THEN** the fresh owner SHALL NOT observe `platform.skip_inventory_rollup = on`
- **AND** an `ocsf_devices` mutation SHALL execute the real inventory-rollup trigger
- **AND** the selected integration source that asserts rollup totals, types, and vendors SHALL
  remain `async: false` in a serial lane

### Requirement: Unsafe integration tests use the serial scope matching their shared state
Affected integration modules SHALL use the serial scope matching their shared state. Modules that
use unboxed transactions, DDL, `TRUNCATE`, materialized-view refresh, application-global
configuration, Oban-wide operations, fixed registries or PubSub topics, unfiltered global telemetry
or logger handlers, global ETS/cache clears, unmanaged children, globally named/application-
supervised processes, or behavior requiring independent real database connections MUST remain
`async: false` in a serial lane and SHALL have a checked-in quarantine reason. Modules that use a fixed
NATS or other fixture-global resource name MUST additionally be pinned to `serial_0` and absent from
the async lane and every other serial lane, unless an audited per-test namespace and scoped
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
- **THEN** every such module SHALL be assigned to designated serial lane `serial_0`
- **AND** every such module SHALL remain `async: false`
- **AND** no source in the async lane or another serial lane SHALL use that fixed resource

#### Scenario: Unique external namespace is reviewed as independent
- **GIVEN** an integration module derives its external resource name from the test or guarded run id
- **AND** cleanup is scoped to that exact resource
- **WHEN** the module is evaluated for a non-designated serial lane or the async lane
- **THEN** the audit SHALL record the uniqueness and cleanup evidence
- **AND** Ecto transaction isolation alone SHALL NOT be accepted as that evidence

### Requirement: Core integration parallelism uses fixed async and serial lanes
The ordinary core integration suite SHALL run exactly one async BEAM at `max_cases: 8` plus exactly
seven serial BEAM lanes at `max_cases: 1`. Every lane SHALL pin a 12-connection Repo pool, use a
distinct disposable `sr_core_test_<run-id>_<lane>` clone on `srql-fixtures`, and collectively use
exactly eight BEAMs / 96 configured core pool slots. Neither `demo` nor a production database is an
eligible endpoint.

Before ExUnit or the application starts, the runner SHALL compare the effective Repo pool from the
loaded test configuration with the topology contract and fail unless it is exactly 12. Logging an
unexpected pool without rejecting it is insufficient because the observer's 114-slot reservation
assumes eight 12-connection pools.

The topology SHALL be chosen and frozen at proposal time from the audited `srql-fixtures` capacity,
not derived from current runtime occupancy. Before provisioning, the observer SHALL read the live
total server usable capacity and fail closed unless
`114 <= floor(0.90 * usable_client_slots)`, where 114 is the fixed 96-slot core topology plus 18
slots for the three SRQL binaries selected by the ordinary wildcard. The observer SHALL record
run-scoped and fixture-wide occupancy peaks but SHALL NOT reduce the lane count or subtract
unrelated live fixture sessions from the fixture-wide samples. Headroom is capacity for
test-supervised processes inside test BEAMs only, never for deployed applications.

#### Scenario: Fixed lane topology is frozen before CPU diagnostics and cohorts
- **GIVEN** the complete selected-module disposition and the proposal-time audit of 197 usable
  fixture client slots
- **WHEN** the ordinary topology is prepared before CPU diagnostics or authoritative cohorts
- **THEN** it SHALL contain exactly one async lane and exactly seven serial lanes
- **AND** every all-async source SHALL appear exactly once in the async lane
- **AND** every selected serial source SHALL appear exactly once in a serial lane
- **AND** every load-only source SHALL appear in no ordinary lane
- **AND** the eight-lane source/identity map and selected-test-count projection SHALL be checked in
  and input-hashed
- **AND** no timing result SHALL retune that map

#### Scenario: Serial lanes are deterministic and fixed external work is isolated
- **GIVEN** the serial source set and exact selected serial test identities emitted by the
  database-free ExUnit selection runner
- **WHEN** serial lanes are assigned
- **THEN** every `fixed_external` source SHALL preseed `serial_0`
- **AND** all remaining serial sources SHALL be ranked by descending deterministic LPT weight
  `1 + selected_serial_test_identity_count` then source path
- **AND** each ranked source SHALL select a lane by current load, then source count, then lane name
- **AND** the checked-in counts SHALL exactly match the current selected identity union
- **AND** no runtime duration SHALL enter the source weight
- **AND** lane-order source counts SHALL be `[26, 22, 22, 23, 23, 22, 22]`
- **AND** lane-order selected-test counts SHALL be `[185, 190, 190, 189, 189, 188, 188]`
- **AND** lane-order structural loads SHALL be `[211, 212, 212, 212, 212, 210, 210]`
- **AND** no async or other serial lane SHALL contain a fixed-external source

#### Scenario: Ordinary provisioning uses one clone per lane
- **WHEN** the ordinary core lifecycle invokes `provision_db`
- **THEN** it SHALL clone exactly the frozen async and serial lane suffixes for that run
- **AND** every database-facing test action SHALL retain local, non-cached execution
- **AND** it SHALL NOT clone the large-ingestion database

#### Scenario: Invalid capacity or concurrency configuration fails
- **GIVEN** a lane receives missing, malformed, zero, negative, or unsupported concurrency settings,
  or live total server capacity cannot fund the fixed 114-slot selected workload with 10% headroom
- **WHEN** `test_helper.exs` configures ExUnit or lifecycle preflight runs
- **THEN** the lifecycle SHALL fail before executing integration tests
- **AND** it SHALL NOT silently use machine scheduler count, a smaller topology, or a
  database outside the disposable fixture namespace

### Requirement: Workflow CPU and Repo capacity are controlled independently
Ordinary integration targets SHALL explicitly pin the test Repo pool size to 12. Before the final
cohorts, workflow CPU allocation SHALL be selected through a same-revision 2-CPU versus 12-CPU
diagnostic so scheduler capacity cannot silently change database capacity or be conflated with test
topology.

#### Scenario: CPU allocation diagnostic changes one factor
- **GIVEN** the frozen async-plus-serial lane source placement
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
  image/pool, and normalized base/CPU2/CPU12 actions with only the later production-winner CPU
  field omitted
- **AND** both SHA/hash tuples SHALL be recorded
- **AND** a hash difference SHALL require all ten CPU attempts to rerun after the frozen after SHA
  is published and before the authoritative cohorts

### Requirement: Lane placement is deterministic and source-level
Final ordinary placement SHALL be source-level and homogeneous: an all-async source belongs only to
the async lane, a serial source belongs only to one serial lane, and a load-only source belongs to
none. The async lane uses ExUnit's cap-eight module scheduler. Serial placement uses only the
pre-measurement LPT rule and MUST NOT treat its relative source weights as wall-time forecasts.

#### Scenario: Lane placement is deterministic
- **GIVEN** complete source/module dispositions and exact selected serial test-identity counts
- **WHEN** ordinary sources are placed repeatedly in different input orders
- **THEN** every selected source SHALL appear in exactly one permitted lane
- **AND** the resulting lane map SHALL be identical
- **AND** a mixed selected-mode source SHALL fail validation until it is split

#### Scenario: Load-only and fixed-external placement are explicit
- **GIVEN** load-only and fixed-external source dispositions
- **WHEN** lane placement is validated
- **THEN** load-only sources SHALL appear in no ordinary lane
- **AND** every fixed-external source SHALL appear only in `serial_0`
- **AND** legacy list membership or read-only external access alone SHALL NOT qualify a source as
  `fixed_external`

### Requirement: Production lane topology is frozen before CPU diagnostics and authoritative timing
The one-async-plus-seven-serial-lanes production topology SHALL not run one/four/eight/hybrid
challenger diagnostics. All timing, CPU selection, and authoritative cohorts use the same frozen
eight-lane count, source map, caps, per-BEAM pool, fixture configuration, retries, and current
template.

#### Scenario: Topology configuration is frozen before CPU diagnostics and cohorts
- **GIVEN** the proposal-time capacity audit and checked-in eight-lane map
- **WHEN** CPU diagnostics or cohorts begin
- **THEN** exactly one async lane SHALL have cap 8
- **AND** exactly seven serial lanes SHALL have cap 1
- **AND** each lane SHALL have pool size 12
- **AND** no timing result SHALL tune lane count, membership, source weight, or cap

#### Scenario: Runtime capacity preflight fails closed without resizing
- **GIVEN** the frozen eight-lane topology and fixed 114-slot ordinary selected workload
- **WHEN** the observer reads the server's live maximum and reserved connection settings
- **THEN** it SHALL require `114 <= floor(0.90 * usable_client_slots)` before readiness and
  provisioning
- **AND** it SHALL fail closed if total server capacity does not meet that requirement
- **AND** it SHALL NOT derive fewer serial lanes from current fixture occupancy
- **AND** it SHALL provision a distinct disposable `sr_core_test_<run>_<lane>` clone on
  `srql-fixtures` for each of the eight frozen lanes

### Requirement: Heavy release qualification is source-separated from pull-request tests
Both large-ingestion release-gate suites and the intact two-pass cold database-bootstrap test SHALL
be source-separated from pull-request tests.
The 50,000-device router ingestion test and the 500-device, three-round identifier-cardinality
gate SHALL live in a Bazel source set that is disjoint from ordinary unit and integration test
source sets. The cold bootstrap source SHALL also be explicitly disjoint from every ordinary lane
while retaining both production startup invocations and their assertions. All three SHALL
run through the explicit
`large_ingestion_release_gate` target against a dedicated disposable database. ExUnit tag
include/exclude precedence MUST NOT be able to select the heavy source from an ordinary
pull-request shard, and the pull-request integration wildcard MUST exclude the dedicated target's
`large_ingestion_test` Bazel tag.

The heavy target's parent `ServiceRadar.Repo` SHALL be pinned to pool size 12. Cold bootstrap SHALL
start its normal child Repo with pool size 2 while the parent Repo remains alive, and
`StartupMigrations` SHALL concurrently open one direct Postgrex administrator connection. The
heavy observer SHALL therefore reserve 15 workload slots before readiness and provisioning,
regardless of the target's serial ExUnit configuration. This focused reservation is independent
of the ordinary wildcard's 114-slot workflow-wide preflight.

#### Scenario: Ordinary integration include cannot select the heavy test
- **GIVEN** the ordinary integration runner positively includes `:integration` and
  `:requires_app`
- **WHEN** Bazel constructs the frozen async and serial lane source sets
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
- **AND** ordinary async and serial lane databases SHALL not be required
- **AND** teardown SHALL remove the dedicated database by the shared run prefix
- **AND** the target SHALL run the two ingestion suites and cold bootstrap serially

#### Scenario: Heavy capacity preflight includes bootstrap pools and direct migration connection
- **GIVEN** the heavy target's parent Repo remains alive while cold bootstrap starts its child Repo
- **WHEN** the BuildBuddy action starts its observer and waits for readiness before
  `provision_db_large_ingestion`
- **THEN** the parent Repo pool size SHALL be exactly 12
- **AND** the cold-bootstrap child Repo pool size SHALL be exactly 2
- **AND** the direct Postgrex administrator connection opened by `StartupMigrations` SHALL count as
  one workload slot
- **AND** the observer SHALL require 15 workload slots
- **AND** `max_cases: 1` SHALL NOT reduce that reservation
- **AND** the action SHALL fail before provisioning when live total server capacity cannot fund all
  15 workload slots while retaining 10% headroom
- **AND** the observer's own administrator connection SHALL be excluded from the workload
  reservation and reported separately

#### Scenario: Cold bootstrap coverage is moved intact
- **GIVEN** cold bootstrap applies the production baseline and migration history on its first pass
- **AND** its second pass covers the normal migrated restart and idempotence
- **WHEN** the test is source-separated from ordinary pull-request lanes
- **THEN** both startup invocations and all assertions SHALL remain unchanged
- **AND** the heavy lifecycle SHALL verify exact scratch-database cleanup or its existing stale
  sweep backstop

#### Scenario: CI cannot lower the release workload
- **WHEN** the BuildBuddy heavy-gate action executes
- **THEN** the router test SHALL ingest 50,000 devices
- **AND** the cardinality test SHALL ingest 500 devices across three rounds
- **AND** a developer-only diagnostic override MUST NOT lower either CI workload

### Requirement: Heavy coverage is a default-branch and release qualification gate
BuildBuddy SHALL run the focused heavy lifecycle on pushes to `staging` and on a nightly UTC
schedule. It SHALL NOT start a second 50GB job from a `v*` tag push: the tag is cut from a
chore commit, the staging merge has a different SHA and the same tree, and a tag-triggered
duplicate sits `queued=true` without an invocation while publication polls the tag SHA.
BuildBuddy's linked GitHub App SHALL publish the classic commit status context
`LargeIngestionGate` for the workflow commit. Release publication MUST wait for a successful
BuildBuddy result for the immutable tag commit **or** a first-parent descendant of that
commit on fetched `origin/staging` whose git tree SHA is identical (the ancestry-preserving
merge).

#### Scenario: Nightly coverage runs outside pull requests
- **GIVEN** the latest default-branch commit
- **WHEN** the nightly BuildBuddy schedule fires
- **THEN** it SHALL run only the focused heavy database lifecycle and target
- **AND** success or failure SHALL be recorded against that commit
- **AND** teardown failure SHALL fail an otherwise successful action

#### Scenario: Release commit lacks heavy-gate evidence
- **GIVEN** a release tag points to a commit that contains the heavy-gate target
- **AND** neither that commit nor a same-tree first-parent descendant on `origin/staging`
  has a successful current `LargeIngestionGate` status
- **WHEN** the release workflow reaches qualification
- **THEN** it SHALL use explicit `statuses: read` permission to query the tag commit and
  those same-tree descendants
- **AND** it SHALL wait for a named classic success for at most 90 minutes
- **AND** it SHALL evaluate only the newest status record per SHA for the exact context
- **AND** it SHALL accept only `success` whose parsed target URL uses HTTPS, host exactly
  `carverauto.buildbuddy.io`, and a nonempty `/invocation/<id>` path
- **AND** a pending or failed status on the tag SHA SHALL NOT fail qualification while a
  same-tree staging descendant is still missing or pending
- **AND** it SHALL stop before artifact publication if every candidate remains missing,
  pending, or terminal-failed

#### Scenario: Staging merge status qualifies the tagged chore commit
- **GIVEN** a release tag points at chore commit T
- **AND** `origin/staging` first-parent history contains merge commit M
- **AND** T is an ancestor of M
- **AND** `git rev-parse T^{tree}` equals `git rev-parse M^{tree}`
- **AND** `LargeIngestionGate` is success on M and pending on T
- **WHEN** the release workflow reaches qualification
- **THEN** it SHALL accept M's success and proceed to publication

#### Scenario: Tag push does not enqueue a second heavy job
- **GIVEN** a `v*` tag is pushed
- **WHEN** BuildBuddy evaluates `LargeIngestionGate` triggers
- **THEN** it SHALL NOT start the heavy action from the tag event
- **AND** the staging-push and nightly triggers remain in force

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
- **THEN** it SHALL run the frozen ordinary async and serial integration lanes
- **AND** its integration target filter SHALL include `-large_ingestion_test`
- **AND** its measured wildcard SHALL use `--build_tests_only` and the same build/test tag filters
- **AND** it SHALL NOT build unrelated package, release-archive, OCI-image, or push targets as part
  of the integration wave
- **AND** it SHALL NOT run the source-separated heavy release-qualification target

### Requirement: Parallel integration acceptance is measured and retry-free
Before bounded concurrency is considered complete, the implementation SHALL pass at least 20
consecutive CI-equivalent ordinary integration lifecycles with test retries disabled. Measurement
SHALL start before fixture configuration materialization and end after successful teardown, with a
current template and the exact Bazel configuration already built. The prebuild SHALL contain the
ordinary integration targets, their dependencies, and the manual connection-observer, sweep,
provision, and teardown targets that run inside the clock. It SHALL exclude unrelated package,
release-archive, OCI-image, and push targets. The measured ordinary wildcard SHALL use
`--build_tests_only` plus identical positive and negative build/test tag filters so excluded tests
and unrelated non-test targets are neither built nor executed inside the clock. The end timestamp
SHALL be captured immediately when teardown returns, before observer shutdown/wait overhead. It
SHALL include all targets selected by the ordinary pull-request integration filter and exclude only
the `large_ingestion_test`-tagged heavy release-qualification target. Across that run set,
nearest-rank p95 SHALL be at most 90 seconds, and relative p95 improvement versus the controlled
before cohort SHALL be at least 50%.
Whether relative improvement reaches the 60% stretch target SHALL be reported. The slowest
non-empty serial lane
SHALL be no more than 1.5 times the fastest, and there SHALL be no sandbox ownership error,
deadlock, leaked test process, leaked disposable database, or retry-masked failure.

The controlled comparison SHALL use the instrumentation-only commit immediately before the first
behavior change as `before`, the final rebalanced implementation as `after`, and one identical
non-merging benchmark harness at both revisions. Both accepted cohorts SHALL contain 20 consecutive
successful, retry-free lifecycle attempts and SHALL retain all failed sequence rows. Authoritative
timed and gating actions SHALL NOT enable ExUnit's built-in slowest reporting because it forces
trace, serial execution, and infinite test timeouts. Each ordinary lane SHALL instead emit an
effective-runner marker showing the declared `max_cases`, trace mode, and timeout mode.

#### Scenario: Acceptance run set is stable
- **GIVEN** current build artifacts and a current database template
- **WHEN** 20 consecutive guarded integration lifecycles run with `--flaky_test_attempts=1`
- **THEN** every lifecycle SHALL pass without an ownership error or PostgreSQL deadlock
- **AND** every lifecycle SHALL complete outcome-bearing teardown
- **AND** no failed test SHALL be hidden by a retry

#### Scenario: Performance target is evaluated
- **GIVEN** timing data from the accepted run set
- **WHEN** the end-to-end integration lifecycle and per-lane durations are summarized
- **THEN** the ordered 19th value of 20 lifecycle durations SHALL be at most 90 seconds
- **AND** relative p95 improvement versus the accepted before cohort SHALL be at least 50%
- **AND** the report SHALL state whether BuildBuddy relative improvement reached the 60% stretch
  target
- **AND** slowest/fastest non-empty serial-lane skew SHALL be at most 1.5
- **AND** the result SHALL use the frozen one-async-plus-seven-serial topology and Repo pool size 12

#### Scenario: Before and after cohorts are comparable
- **GIVEN** the instrumentation-only before commit is the direct parent of the first behavior change
- **WHEN** BuildBuddy executes alternating before/after attempts
- **THEN** each request SHALL name and verify the exact source SHA without a synthetic merge
- **AND** the normalized benchmark action, observer sources, observer Bazel rule, runner image,
  workflow pool, explicit CPU allocation, Repo pool size 12, flags, and target selection SHALL be
  identical
- **AND** the before lanes SHALL report `max_cases: 1`, the intermediate safety wave SHALL report
  `max_cases: 2`, and the final after map SHALL report async `max_cases: 8` and serial `max_cases: 1`
- **AND** all authoritative cohort lanes SHALL report trace disabled and timeouts enabled
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
- **AND** every accepted after attempt SHALL use exactly eight BEAMs / 96 configured core pool slots
- **AND** the ordinary wildcard's three existing SRQL binaries SHALL add at most 18 configured
  connections, for a workflow-wide preflight requirement and run-scoped peak limit of 114
- **AND** fixture-wide peak SHALL retain unrelated live fixture sessions, exclude only the
  observer's reported administrator session, and be at most `floor(usable client slots * 0.90)`

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

For CI and fixed-lane measurements, the fixture SHALL be the development-only `srql-fixtures` CNPG
cluster. Every suite lane SHALL target a disposable database named
`sr_core_test_<unique-run-id>_<lane>` (or its explicitly source-separated release-gate suffix).
Neither `demo` nor any production database is a valid endpoint. Any Repo-pool headroom described by
this change is capacity for processes supervised inside the test BEAM, not capacity reserved for a
deployed application.

#### Scenario: Benchmark cannot target demo or production
- **GIVEN** an ordinary, heavy, CPU-diagnostic, or cohort BuildBuddy lifecycle
- **WHEN** fixture credentials and database names are materialized
- **THEN** the lifecycle SHALL use the `srql-fixtures` fixture configuration
- **AND** every provisioned suite database SHALL remain inside the `sr_core_test_` disposable
  namespace with its unique run id and lane suffix
- **AND** a missing fixture configuration or invalid disposable name SHALL fail before provisioning
- **AND** the lifecycle SHALL NOT accept `demo` or production database configuration

#### Scenario: Concurrent ordinary suite uses the existing fixture boundary
- **WHEN** the ordinary action enables in-shard concurrency
- **THEN** it SHALL still execute
  `sweep -> prepare -> conditional migrate -> provision -> suite -> teardown`
- **AND** fixture credentials SHALL remain absent from generic remote unit-test actions
- **AND** database TLS SHALL retain live-CA and hostname verification

#### Scenario: Focused direct Mix invocation fails closed outside srql-fixtures
- **GIVEN** a developer supplies a database URL to a direct Mix test invocation
- **WHEN** test configuration is evaluated before Repo startup
- **THEN** the destination SHALL identify the `srql-fixtures` TLS server
- **AND** it SHALL require `sslmode=verify-full` plus the fixture CA
- **AND** it SHALL target a disposable `sr_core_test_*` or `codex_*` database
- **AND** it SHALL reject `demo`, production, the shared `srql_fixture` database, and the
  `sr_core_template` database outside the typed template-migration lifecycle

#### Scenario: Fixture configuration transport changes first
- **GIVEN** config-manager adoption removes the current fixture environment bridge
- **WHEN** this change is implemented or rebased
- **THEN** ordinary and heavy targets SHALL consume the replacement contract
- **AND** they SHALL NOT recreate the retired bridge
- **AND** their database naming, sandbox isolation, and scheduling semantics SHALL remain unchanged
