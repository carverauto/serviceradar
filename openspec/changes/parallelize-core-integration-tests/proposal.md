# Change: Parallelize core integration tests safely

## Why
The core integration phase is the dominant warm-cache CI cost. In five recent successful
BuildBuddy pull-request runs it took 2m21s to 4m22s, with a typical result near 2m27s. The legacy
eight-Bazel-shard layout uses separate template-cloned databases, but every shard forces ExUnit to
`max_cases: 1`, so database-safe modules inside each BEAM still run serially.

The suite already has the Elixir equivalent of Marvin's Diesel pattern: `ServiceRadar.DataCase`
starts a rollback-only Ecto SQL Sandbox owner for each test and stops it on exit. The missing work
is to make the owner lifecycle safe for concurrent modules, explicitly allow test-owned child
processes, and keep tests that mutate process-global or database-global state in a serial lane.

The first implementation pass proved the owner lifecycle but did not yet exploit it broadly. Of
the 222 ordinary selected DataCase modules, 220 remain `async: false`; the two promoted database
modules are assigned to different shards and therefore never overlap each other. The latest green local wave
completed in 203.02 seconds versus the first complete green treatment's 259.00 seconds, a 21.6%
improvement driven primarily by heavy-source extraction, work reduction, and sum-weighted shard
balancing. ExUnit concurrency is module-level, so reaching the approved 50% minimum requires broad
module promotion, splitting mixed safe/unsafe modules, and placement that models serial work and
async makespan separately.

Two ingestion/cardinality release gates also run in every pull request. The 50,000-device router
test alone contributes about 47 seconds. One gate has both `:integration` and `:large_ingestion`;
the other inherits `:requires_app` from DataCase and has `:large_ingestion`. ExUnit's positive
`include: [:integration, :requires_app]` selection overrides the `:large_ingestion` exclusion in
both cases. A tag-only fix would leave that precedence trap in place.

The cold database-bootstrap integration test is a different kind of heavy work with the same PR
latency consequence. It deliberately starts the production migration path twice against a fresh
database: the first pass applies the baseline plus all migrations, and the second proves normal
restart idempotence. A quiet serial profile was already about 115 seconds, above the complete
90-second PR lifecycle goal, and its first pass exceeded 300 seconds while contending with the
eight-shard treatment. Parallelizing shard databases cannot divide that sequential DDL workload.

## What Changes
- Replace production eight-way source sharding with exactly one shared async BEAM at frozen
  `max_cases: 8` and exactly seven serial BEAM lanes at `max_cases: 1`. Every lane receives
  its own disposable `sr_core_test_<run-id>_<lane>` clone on `srql-fixtures`; neither `demo` nor a
  production database is an eligible endpoint.
- Pin every lane's Repo pool at 12 and freeze the topology at eight BEAMs / 96 configured core pool
  slots. This one-async-plus-seven-serial shape was selected at proposal time from the audited
  `srql-fixtures` capacity of 197 usable client slots. The ordinary wildcard also selects three
  existing SRQL integration binaries with 18 possible connections, so the fixed selected workload
  requires 114 slots. Before provisioning, the runtime observer fails closed unless the server's
  live total usable capacity can fund all 114 slots while retaining 10% headroom. It records live
  run-scoped and fixture-wide occupancy peaks, but it does not derive a smaller lane count from
  current occupancy or subtract unrelated live sessions from the fixture-wide samples. Any spare
  pool connections are capacity for processes supervised inside a test BEAM, never for deployed
  applications.
- Configure suite-global test state once in `test_helper.exs`; make ordinary no-option
  `start_core!` calls idempotent and free of Application-environment mutation before async modules
  are scheduled.
- Refine the Ecto SQL Sandbox lifecycle so concurrent tests keep independent rollback-only owners
  and one owner cannot reset or check in another owner's connection.
- Add a project-owned helper for explicitly granting a test-owned child process access to the
  calling test's sandbox transaction.
- Account for every ordinary source and classify every selected ExUnit module, including direct
  DataCase and non-DataCase modules, into:
  - a transaction-isolated lane that may opt in with `async: true`;
  - a serial lane for unboxed transactions, DDL, `TRUNCATE`, materialized-view refreshes,
    application-environment mutation, and shared application processes; and
  - designated serial lane `serial_0` for tests that share fixed NATS or other fixture-global resource
    names across BEAMs.
- Promote every transaction-isolated module found by that audit, record a concrete checked-in
  blocker for every quarantined serial module, and split mixed modules so their transaction-only
  cases can run async while unsafe cases retain the narrow serial scope they require.
- Classify files with no `:integration` or `:requires_app` cases as load-only, prove an all-source
  control and the pruned source union enumerate the same selected test identities, and stop loading
  those unit-only files into database-backed shards. Unit targets retain their complete source set.
- Normalize fixed registry keys, PubSub topics, telemetry filters, cache keys, and other identifiers
  only when they can become unique per test with exact scoped cleanup.
- Benchmark the BuildBuddy workflow at explicit 2-CPU and 12-CPU allocations as an independent
  factor, pin the integration Repo pool to 12 during that comparison, and print scheduler/pool
  values so CPU sizing cannot silently masquerade as a database-capacity increase. Apply the
  winning explicit request to production `BazelCI` and both authoritative benchmark revisions so
  accepted latency represents pull-request capacity.
- Fail fast when a test attempts the invalid combination of `async: true` and
  `sandbox: :unboxed`.
- Move both large-ingestion suites and the intact two-pass cold database-bootstrap test into one
  source-separated heavy release-qualification target backed by its own disposable database, so
  ordinary pull-request integration targets cannot select any of them through ExUnit include
  precedence. Introduce the target/status identifiers as permanent stable contracts and use marker
  ancestry to preserve genuinely historical release behavior.
- Pin the heavy target's parent `ServiceRadar.Repo` pool to 12 and the normal child Repo used by
  cold bootstrap to 2. The parent remains alive while that child runs, and
  `StartupMigrations` concurrently opens one direct Postgrex administrator connection. The heavy
  observer must therefore reserve 15 workload slots before readiness and provisioning. The
  observer's own session remains separately excluded and reported. This focused 15-slot
  reservation is distinct from the ordinary wildcard's 114-slot workflow-wide preflight.
- Give the dedicated target a `large_ingestion_test` Bazel tag and make the pull-request integration
  wildcard use `--build_tests_only` with matching build/test tag filters that explicitly exclude
  it. This keeps the separate target, packages, release archives, OCI images, and push targets out
  of the ordinary integration wave.
- Run the heavy target in a separate BuildBuddy action on the default branch, nightly, and for
  release tags; keep the full bootstrap and ingestion assertions unchanged; require a successful
  result for the exact release commit before publication using
  a tested Bazel qualifier and permanent introduction marker that distinguish truly historical
  tags from later contract deletion.
- Freeze the final source membership before CPU diagnostics and authoritative cohorts: every
  all-async source goes to the one async BEAM; `load_only` sources are excluded; serial sources are
  LPT-balanced across the selected serial lanes: rank by descending
  `1 + selected_serial_test_identity_count` then source path, and select the destination lane by
  current load, source count, then lane name. Every `fixed_external` source is preseeded in
  `serial_0`. The counts come from the existing database-free runner using ExUnit's real filters
  and are checked against the selected identity union. Runtime timings do not enter the weight.
  Once that manifest-backed map is frozen, no diagnostic may retune lane count or membership.
- Require the authoritative exact-SHA BuildBuddy after cohort to improve nearest-rank p95 by at
  least 50% versus the controlled before cohort and to remain at or below 90 seconds. Report 60%
  as the stretch result. Retain the 259.00-second host-local run as historical diagnostic evidence,
  not as an acceptance baseline for a fixture lifecycle the current workstation cannot reproduce.
- Add hermetic configuration tests and repeated CI-equivalent stress runs that enforce the lane
  boundaries, source separation, database naming, and stability contract.

## Non-Goals
- Replace Ecto SQL Sandbox with a custom transaction implementation.
- Run DDL, unboxed, NATS, or process-global tests concurrently.
- Increase the eight-BEAM / 96-slot capacity envelope or any per-BEAM Repo pool size during the
  staged rollout.
- Reintroduce one/four/eight/hybrid topology-challenger diagnostics or retune the final lane count
  or manifest-backed source map after observing timings.
- Create a database or BEAM VM per individual test file.
- Shorten cold full-repository compilation; this proposal targets the integration lifecycle after
  build artifacts and the database template are current.
- Reduce the 50,000-device or 500-device/three-round workloads, or remove either from release
  qualification.
- Reduce the cold bootstrap test to one startup pass, skip the baseline path, or weaken its
  idempotence assertions.
- Change fixture credential, cache routing, TLS verification, or template-migration semantics.

## Impact
- Affected specs:
  - `integration-test-execution` (new capability)
- Affected code and operations:
  - `build/integration_shards.bzl`
  - `elixir/serviceradar_core/BUILD.bazel`
  - `elixir/serviceradar_core/test/test_helper.exs`
  - `elixir/serviceradar_core/test/support/data_case.ex`
  - `elixir/serviceradar_core/test/support/test_support.ex`
  - exhaustive async/serial DataCase disposition inventory and audited module splits
  - audited core integration test modules
  - `elixir/serviceradar_core/test/serviceradar/results_router_integration_test.exs`
  - `elixir/serviceradar_core/test/release_gates/large_ingestion/identifier_cardinality_release_gate_test.exs`
  - source-separated large-ingestion release-gate modules
  - `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs`
  - `openspec/changes/parallelize-core-integration-tests/benchmark.md`
  - `rust/integration-db/BUILD.bazel` and lifecycle tests
  - `buildbuddy.yaml`
  - `.github/workflows/release.yml`
  - `build/ci/large_ingestion_gate_contract.v1` and the Bazel-owned release qualifier
  - Bazel configuration and source-partition tests
  - non-gating CPU diagnostic targets and fixed-lane runner markers
- Coordination:
  - Preserve the guarded lifecycle and local, non-cached database `TestRunner` contract from
    `route-bazel-cache-through-shared-edge`.
  - Preserve live-CA, `verify-full`, and credential-isolation behavior from
    `add-srql-fixture-cert-manager-tls`.
  - Rebase workflow and environment changes on the final shape of
    `complete-config-manager-adoption`; this proposal depends on fixture values being available,
    not on whether they arrive through the current environment bridge or config manager.
