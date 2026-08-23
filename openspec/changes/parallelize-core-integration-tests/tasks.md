## 1. Isolation contract and regression tests
- [ ] 1.1 Add focused TestSupport/DataCase tests that prove two non-shared owners can coexist and
      stopping one owner does not check in or reset the other owner's transaction.
- [ ] 1.2 Add a failing test for `async: true` combined with `sandbox: :unboxed`, then implement the
      fail-fast guard without changing the existing serial unboxed path.
- [ ] 1.3 Add a project-owned sandbox allowance helper and tests proving a test-owned child can see
      its parent's uncommitted writes while a different owner cannot; cover `:ok`,
      `{:already, :allowed}`, `{:already, :owner}`, and `:not_found` results.
- [ ] 1.4 Split owner teardown into async/non-shared and serial/shared paths; keep global task drains
      and `Sandbox.mode(Repo, :manual)` out of the async path.
- [ ] 1.5 Replace context-free `with_repo_owner/1` with `with_repo_owner(context, fun)`, migrate its
      callers, and add a test proving `context[:async]` is rejected before the shared-owner path
      changes pool mode.
- [ ] 1.6 Document the async eligibility and serial exception criteria in DataCase/TestSupport
      module documentation and in the core test helper guidance.

## 2. Source-separated large-ingestion gate
- [ ] 2.1 Move the 50,000-device router case and the identifier-cardinality gate into release-gate
      sources while keeping the smaller ResultsRouter integration assertion in the ordinary suite.
- [ ] 2.2 Exclude the release-gate source directory from `ALL_TEST_SRCS` and add an explicit
      `large_ingestion_release_gate` Bazel target with the declared run-id file, integration
      environment preloads, fixed 50,000-device and 500-device/three-round CI values, and complete
      runtime data.
- [ ] 2.3 Add a shared `large_ingestion` database suffix and a focused
      `//rust/integration-db:provision_db_large_ingestion` target without adding that database to
      ordinary eight-shard provisioning.
- [ ] 2.4 Add lifecycle/configuration tests proving the Elixir target and Rust provision target
      derive the same database name, ordinary unit/integration targets exclude the heavy source,
      the pull-request integration wildcard excludes the `large_ingestion_test` Bazel tag, and
      teardown owns the dedicated suffix.
- [ ] 2.5 Prove the release target runs both full workloads and the ordinary PR integration suite
      neither embeds nor selects either release gate.

## 3. Bounded in-shard concurrency
- [ ] 3.1 Define the checked-in integration `max_cases` constant as 2, pass it to all eight generated
      Bazel targets, and make `test_helper.exs` fail closed on an invalid integration value.
- [ ] 3.2 Add a hermetic Bazel configuration test proving all eight shards use the same cap and
      ordinary unit targets do not inherit the integration override.
- [ ] 3.3 Audit core DataCase integration modules against the design's transaction-only criteria and
      record every promoted module, its isolation scope, and any child-process allowance it
      requires.
- [ ] 3.4 Convert the audited transaction-only set to `async: true`; keep unboxed, DDL, `TRUNCATE`,
      materialized-view, application-environment, global-process, and true multi-connection modules
      explicitly serial within their shard.
- [ ] 3.5 Replace eligible test-owned background process usage with supervised lifetime and explicit
      sandbox allowances; do not grant one global application process to concurrent owners.
- [ ] 3.6 Pin tests using fixed NATS or other fixture-global resource names to the designated `s7`
      source class, keep them `async: false`, and add a partition test proving no other shard
      contains those sources; document any audited unique-namespace exception.

## 4. BuildBuddy and release qualification
- [ ] 4.1 Add a separate BuildBuddy action for the focused heavy lifecycle, triggered on pushes to
      `staging`, a nightly UTC schedule, and release tags, with classic GitHub status context
      `LargeIngestionGate`.
- [ ] 4.2 Reuse the guarded template, fixture TLS, credential scoping, local non-cached TestRunner,
      unique run-id, and outcome-bearing teardown contracts; do not duplicate or restore a retired
      fixture environment bridge.
- [ ] 4.3 Give the release workflow explicit `statuses: read` permission and poll the exact tag
      commit's classic `LargeIngestionGate` status for at most 30 minutes before publication,
      accepting only the newest matching record when it is successful and its parsed HTTPS URL has
      host exactly `carverauto.buildbuddy.io` plus a nonempty invocation id.
- [ ] 4.4 Atomically add a permanent `build/ci/large_ingestion_gate_contract.v1` introduction marker
      with the complete Bazel-owned, unit-tested release qualifier and workflow wiring, covering
      ancestry-based applicability, complete
      marker-bearing trees, missing/repeated introduction evidence, divergent histories,
      newest-status selection, BuildBuddy URL validation, pagination, and timeout/error behavior.
- [ ] 4.5 Add static workflow tests covering the trigger set, focused targets, retry policy,
      pull-request `-large_ingestion_test` filter, credential boundaries, teardown, qualifier
      invocation, and release-status context.
- [ ] 4.6 Keep historical tag retries compatible only when the immutable release commit is a strict
      ancestor of the marker's first addition on `origin/staging` first-parent history. Fail closed
      when the introduction is an ancestor of a markerless release, when the commits are divergent,
      when introduction evidence cannot be established, or when a marker-bearing tree lacks the
      target or action; require a manually backfilled BuildBuddy result rather than a bypass for
      applicable commits.

## 5. Measurement, balancing, and acceptance
- [ ] 5.0 Lock the before/after cohort identities, clock boundaries, flags, calculations, evidence
      schema, connection headroom, and pass/fail goals in `benchmark.md` before behavior changes.
- [ ] 5.1 Add and test a Bazel-owned connection observer plus an instrumentation-only,
      non-merging `IntegrationBenchmark` action; make that commit the direct parent of the first
      behavior change and keep the harness identical at the final revision.
- [ ] 5.2 Capture per-shard duration, maximum sampled fixture/run connections, live connection
      capacity, observer-session exclusion, UTC sample window, pre-teardown zero samples, and the
      ordinary lifecycle through outcome-bearing teardown with Bazel and workflow retries disabled;
      use literal database-prefix matching rather than unescaped SQL `LIKE`, preflight migrations
      outside the clock, and capture the end timestamp immediately when teardown returns.
- [ ] 5.3 Run alternating exact-SHA cohorts until both revisions have 20 consecutive successful
      lifecycles; retain all failed sequence rows and require zero ownership errors, deadlocks,
      leaked database processes, leaked databases, or retry-masked failures.
- [ ] 5.4 Recompute the heavy-source partition hints after the release-gate extraction and async
      promotion, then require slowest/fastest non-empty shard skew no greater than 1.5.
- [ ] 5.5 Demonstrate nearest-rank p95 at or below 90 seconds over the accepted 20-run after cohort,
      including the existing SRQL/other integration targets and excluding only the large-ingestion
      gate, without increasing the eight-shard count or Repo pool sizes.
- [ ] 5.6 Run the focused large-ingestion lifecycle repeatedly, verify successful default-branch
      status publication, and prove teardown removes every matching database.

## 6. Repository verification
- [ ] 6.1 Reconcile implementation with `complete-config-manager-adoption`,
      `route-bazel-cache-through-shared-edge`, and `add-srql-fixture-cert-manager-tls`.
- [ ] 6.2 Run focused Elixir support tests, Rust lifecycle tests, Bazel configuration tests, all
      eight core integration shards, and the large-ingestion release gate.
- [ ] 6.3 Run `make lint`, `make test`, and `git diff --check`.
- [ ] 6.4 Run `openspec validate parallelize-core-integration-tests --strict`.
