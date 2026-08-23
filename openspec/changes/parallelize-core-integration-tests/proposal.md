# Change: Parallelize core integration tests safely

## Why
The core integration phase is the dominant warm-cache CI cost. In five recent successful
BuildBuddy pull-request runs it took 2m21s to 4m22s, with a typical result near 2m27s. The eight
Bazel shards already run in parallel and use separate template-cloned databases, but every shard
forces ExUnit to `max_cases: 1`, so database-safe modules inside each BEAM still run serially.

The suite already has the Elixir equivalent of Marvin's Diesel pattern: `ServiceRadar.DataCase`
starts a rollback-only Ecto SQL Sandbox owner for each test and stops it on exit. The missing work
is to make the owner lifecycle safe for concurrent modules, explicitly allow test-owned child
processes, and keep tests that mutate process-global or database-global state in a serial lane.

One 50,000-device ingestion test also contributes about 47 seconds to every pull request even
though it is documented as a release gate. Its module has both `:integration` and
`:large_ingestion`; ExUnit's positive `include: [:integration, :requires_app]` selection overrides
the `:large_ingestion` exclusion. A tag-only fix would leave that precedence trap in place.

## What Changes
- Retain the existing eight database-backed Bazel shards and add bounded ExUnit concurrency inside
  each shard, starting at two concurrently scheduled async modules per BEAM.
- Refine the Ecto SQL Sandbox lifecycle so concurrent tests keep independent rollback-only owners
  and one owner cannot reset or check in another owner's connection.
- Add a project-owned helper for explicitly granting a test-owned child process access to the
  calling test's sandbox transaction.
- Classify integration modules into:
  - a transaction-isolated lane that may opt in with `async: true`;
  - a shard-serial lane for unboxed transactions, DDL, `TRUNCATE`, materialized-view refreshes,
    application-environment mutation, and shared application processes; and
  - a designated outer-shard lane for tests that share fixed NATS or other fixture-global resource
    names across BEAMs.
- Fail fast when a test attempts the invalid combination of `async: true` and
  `sandbox: :unboxed`.
- Move the 50,000-device ingestion case into a source-separated Bazel release-gate target backed
  by its own disposable database, so ordinary pull-request integration targets cannot select it
  through ExUnit include precedence.
- Give the dedicated target a `large_ingestion_test` Bazel tag and explicitly exclude that tag from
  the pull-request integration wildcard, so the separate target itself is not selected by
  `--test_tag_filters=integration_test`.
- Run the heavy target in a separate BuildBuddy action on the default branch, nightly, and for
  release tags; require a successful result for the exact release commit before publication.
- Re-measure and rebalance the eight file partitions after concurrency and the heavy-test
  extraction change the critical path.
- Add hermetic configuration tests and repeated CI-equivalent stress runs that enforce the lane
  boundaries, source separation, database naming, and stability contract.

## Non-Goals
- Replace Ecto SQL Sandbox with a custom transaction implementation.
- Run DDL, unboxed, NATS, or process-global tests concurrently.
- Increase the eight-shard count or the existing Repo pool sizes in the initial rollout.
- Create a database or BEAM VM per individual test file.
- Shorten cold full-repository compilation; this proposal targets the integration lifecycle after
  build artifacts and the database template are current.
- Reduce the 50,000-device workload or remove it from release qualification.
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
  - audited core integration test modules
  - `elixir/serviceradar_core/test/serviceradar/results_router_integration_test.exs`
  - a new source-separated large-ingestion test module
  - `rust/integration-db/BUILD.bazel` and lifecycle tests
  - `buildbuddy.yaml`
  - `.github/workflows/release.yml`
  - Bazel configuration and source-partition tests
- Coordination:
  - Preserve the guarded lifecycle and local, non-cached database `TestRunner` contract from
    `route-bazel-cache-through-shared-edge`.
  - Preserve live-CA, `verify-full`, and credential-isolation behavior from
    `add-srql-fixture-cert-manager-tls`.
  - Rebase workflow and environment changes on the final shape of
    `complete-config-manager-adoption`; this proposal depends on fixture values being available,
    not on whether they arrive through the current environment bridge or config manager.
