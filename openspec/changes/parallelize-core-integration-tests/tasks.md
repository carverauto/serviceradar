## 1. Isolation contract and regression tests
- [x] 1.1 Add focused TestSupport/DataCase tests that prove two non-shared owners can coexist and
      stopping one owner does not check in or reset the other owner's transaction.
- [x] 1.2 Add a failing test for `async: true` combined with `sandbox: :unboxed`, then implement the
      fail-fast guard without changing the existing serial unboxed path.
- [x] 1.3 Add a project-owned sandbox allowance helper and tests proving a test-owned child can see
      its parent's uncommitted writes while a different owner cannot; cover `:ok`,
      `{:already, :allowed}`, `{:already, :owner}`, and `:not_found` results.
- [x] 1.4 Split owner teardown into async/non-shared and serial/shared paths; keep global task drains
      and `Sandbox.mode(Repo, :manual)` out of the async path.
- [x] 1.5 Replace context-free `with_repo_owner/1` with `with_repo_owner(context, fun)`, migrate its
      callers, and add a test proving `context[:async]` is rejected before the shared-owner path
      changes pool mode.
- [x] 1.6 Document the async eligibility and serial exception criteria in DataCase/TestSupport
      module documentation and in the core test helper guidance.
- [x] 1.7 Fail closed before Repo startup when any database-backed direct Mix invocation does not
      present the `srql-fixtures` TLS identity, `verify-full`, the fixture CA, and a disposable
      `sr_core_test_*` or `codex_*` database name. Permit `sr_core_template` only for the typed
      template-migration lifecycle.

## 2. Source-separated heavy release qualification
- [x] 2.1 Move the 50,000-device router case and the identifier-cardinality gate into release-gate
      sources while keeping the smaller ResultsRouter integration assertion in the ordinary suite.
- [x] 2.2 Exclude the release-gate source directory and the cold database-bootstrap source from
      `ALL_TEST_SRCS`, and add an explicit
      `large_ingestion_release_gate` Bazel target with the declared run-id file, integration
      environment preloads, fixed 50,000-device and 500-device/three-round CI values, and complete
      runtime data.
- [x] 2.3 Add a shared `large_ingestion` database suffix and a focused
      `//rust/integration-db:provision_db_large_ingestion` target without adding that database to
      ordinary eight-shard provisioning.
- [x] 2.4 Add lifecycle/configuration tests proving the Elixir target and Rust provision target
      derive the same database name, ordinary unit/integration targets exclude the heavy source,
      the pull-request integration wildcard uses `--build_tests_only` with matching build/test tag
      filters that exclude `large_ingestion_test`, no unrelated top-level target enters the
      integration wave, and teardown owns the dedicated suffix.
- [x] 2.5 Prove the release target runs both full ingestion workloads plus the intact two-pass cold
      database-bootstrap test, and the ordinary PR integration suite neither embeds nor selects
      any of those heavy sources. Keep the newly introduced target/action/status identifiers
      permanent and stable.
- [ ] 2.6 Exercise the broadened heavy target serially under its real lifecycle, verify it remains
      within the action deadline, verify the parent Repo is pinned to 12, the concurrent
      cold-bootstrap child Repo is pinned to 2, and the direct Postgrex administrator connection
      opened by `StartupMigrations` counts as one more workload slot. Verify the observer reserves
      all 15 workload slots before readiness and provisioning, then prove both the dedicated
      run-prefix database and bootstrap's separately named scratch database are removed.

## 3. Bounded in-shard concurrency and broad promotion
- [x] 3.1 Define the checked-in integration `max_cases` constant as 2, pass it to all eight generated
      Bazel targets, and make `test_helper.exs` fail closed on an invalid integration value.
- [x] 3.2 Add a hermetic Bazel configuration test proving all eight shards use the same cap and
      ordinary unit targets do not inherit the integration override.
- [x] 3.3 Complete the initial narrow audit against the design's transaction-only criteria and
      record the two promoted modules, their isolation scope, and any child-process allowance they
      require. This is migration evidence, not the required full-inventory disposition.
- [x] 3.4 Convert the initial two-module transaction-only set to `async: true`; keep unboxed, DDL, `TRUNCATE`,
      materialized-view, application-environment, global-process, and true multi-connection modules
      explicitly serial within their shard.
- [x] 3.5 Replace eligible test-owned background process usage with supervised lifetime and explicit
      sandbox allowances; do not grant one global application process to concurrent owners.
      Completed as an audited no-op: neither promoted module starts a database child, while modules
      that reach application-global processes remain serial and are protected by static contracts.
- [x] 3.6 Pin tests using fixed NATS or other fixture-global resource names to the designated `s7`
      source class, keep them `async: false`, and add a partition test proving no other shard
      contains those sources; document any audited unique-namespace exception.
- [x] 3.7 Reproduce and eliminate DBConnection checkout drops under the full eight-shard candidate
      load with built-in slowest reporting absent and actual `max_cases: 2`, without increasing
      Repo pool sizes or merely raising the dominant allocator test's timeout; add a focused
      regression for any queue/ownership change and rerun a green diagnostic wave before freezing
      the after revision.
- [x] 3.8 Keep the allocator capacity check at the exact 258-identity boundary, run only that test
      unboxed with at most ten concurrent ingests against the unchanged 12-connection pool, register
      exact cleanup before writes, and retain focused trace-free timing evidence.
- [x] 3.9 Reclassify the two remote-access transaction races as per-test unboxed cases; prove four
      distinct checked-out backend connections reach the guarded row lock concurrently, retain the
      one-winner/three-loser assertions, and register failure-safe exact committed-state cleanup
      before the first write.
- [x] 3.10 Replace the ingestor-conflict test's 130 identical handlerless replays with a fixed-point
      assertion over one replay of each digest. Retain both arrival orders and state-repair
      assertions, document that the separate handler-generation suite covers generation changes,
      and retain trace-free focused module timing evidence.
- [x] 3.11 Replace implicit 100ms process-synchronization receives in true concurrency tests with
      explicit bounded waits justified by the test deadline, then verify the focused identity race
      under `max_cases: 2` without weakening its lock proof.
- [x] 3.12 Anchor stalled-dispatch reconciliation tests to the production-persisted `started_at`
      timestamp rather than an earlier synthetic clock; retain the deterministic traced RED and
      five-consecutive-run traced GREEN evidence.
- [x] 3.13 Add a RED/GREEN startup-neutrality regression; make no-option `start_core!` preserve
      Application configuration, make `test_helper.exs` explicitly establish synchronous audit
      writes once, and remove redundant startup blocks from promoted modules.
- [ ] 3.14 Promote the nine fully audited broad-wave modules (seeder reconciliation, dispatcher
      delivery/grouping, action redemption, delivery isolation, suppression dedupe, DIRE
      remediation, sweep-results flow, and agent-config credential delivery) and run focused
      collision/stability tests at cap two.
      Status: all nine are included in the exhaustive async promotion, but the requested focused
      cap-two collision/stability run remains pending.
- [ ] 3.15 Split or normalize the prioritized mixed modules: endpoint-inventory unboxed races,
      dispatcher-routing fixed PubSub assertions, dispatcher-edge registry keys, agent-gateway
      release-signing configuration, dispatcher telemetry filtering, sync/cache identifiers,
      identity telemetry, remote-access session races, and agent-command-bus global processes.
      Promote each safe remainder and retain exact serial quarantine for every extracted blocker.
- [x] 3.16 Build the final exhaustive checked-in disposition with one unique `(source, module)` row
      for every selected DataCase/non-DataCase module and one load-only sentinel only for a source
      with zero selected modules. Prove all-source and pruned-source selected test identities are
      equal before excluding unit-only files from integration shards; reject missing, duplicate,
      fixed-resource-async, mixed-selected-mode, and module-local global configuration cases.
      Status: the 786-source / 283-selected-module disposition, exact Starlark projection, and real
      all-source/pruned ExUnit-filter equivalence over `(source, module, test-name)` identities are
      checked in and enforced. The first real run found 19 modules whose nested support macro
      injects `:requires_app`; those false load-only rows are now serial integration coverage, and
      mutation testing proves an omitted selected identity fails.
- [x] 3.17 Complete the exhaustive audit, split every mixed selected-mode source, and freeze one
      async source set plus serial source set before timing; exclude load-only sources.
      Status: final review moved all seven selected modules with unfiltered VM-global telemetry
      handlers and the anomaly profile seeder module with VM-global Logger configuration from async
      to serial, leaving 123 async and 160 serial selected modules. The only product async module that
      attaches telemetry now filters in the callback by its unique `agent_uid` before forwarding an
      event to the test process, and a static contract rejects `Logger.configure/1` in async modules.
- [x] 3.18 Pin every ordinary BEAM's Repo pool at 12 and implement the proposal-time frozen topology:
      one async lane at cap eight plus exactly seven serial lanes at cap one, for eight BEAMs / 96
      configured core pool slots. Require the runtime observer to fail closed unless live total
      server usable capacity funds the fixed 114-slot ordinary selected workload with 10% headroom;
      do not resize the topology from current occupancy. Validate the effective Repo pool against
      the exact 12-connection topology before ExUnit or the application starts.
- [x] 3.19 Deterministically preseed all fixed-external sources in `serial_0`, LPT-balance remaining
      serial sources by `1 + selected_serial_test_identity_count`, and prove that the checked-in
      counts exactly match the database-free ExUnit selection manifest and produce exact,
      disjoint, glob-order-independent source/identity membership before CPU diagnostics or
      authoritative cohorts. Every lane must use its own disposable
      `sr_core_test_<run-id>_<lane>` clone. The superseded module-count candidate is invalidated:
      all 159 weights were identical and its first smoke failed the 1.5 serial-lane balance gate.
      Status: the executable selection-equivalence contract verifies all 160 checked-in counts
      against 1,319 real selected ExUnit identities. The deterministic partition has selected-test
      counts `[185, 190, 190, 189, 189, 188, 188]`, source counts
      `[26, 22, 22, 23, 23, 22, 22]`, and structural LPT loads
      `[211, 212, 212, 212, 212, 210, 210]`; reverse-input construction is identical and all three
      fixed-external sources remain in `serial_0`.
- [ ] 3.20 Run five attempts per arm, alternating same-revision BuildBuddy diagnostics at explicit 2 CPU and 12 CPU
      with Repo pool 12 and all other factors fixed. Record scheduler/pool markers and select one
      explicit CPU request for production `BazelCI` and both authoritative revisions. Twelve CPUs
      is selectable only with five safety-clean runs. If both are selectable, 12 CPUs wins only
      with a median at least 10% lower; if one is selectable use it, and if neither is, stop.
- [x] 3.21 Run the fixed production topology through a fresh trace-free, timeout-enabled,
      retry-free, observer-covered safety wave. Require zero ownership errors, deadlocks, queue
      drops, process/database residue, or connection-threshold violations; do not run one/four/
      eight/hybrid challenger diagnostics or retune the manifest-backed membership from the
      result. The exact-SHA `a6fde460627429338adb76e21884c49cd7c257cf` candidate was safety-clean
      and completed its measured lifecycle in 86.480 seconds, but its serial-lane skew was
      `45.047 / 24.518 = 1.837`; retain it only as invalidated module-count-map evidence.
      Status: the replacement-map smoke at exact SHA
      `75f8fec704d56cafeec8fc9f618d99a44575c48b` ran all 12 selected targets once, passed 2,030
      Elixir tests without a retry or safety signature, completed the selected test child in
      75.872 seconds and the guarded lifecycle in 120.862 seconds, and reduced runtime serial-lane
      skew to `49.417 / 40.221 = 1.229`. The observer reported run-scoped/fixture-wide peaks of
      96/97 against 197 usable slots; suite, observer, and outcome-bearing teardown statuses were
      zero. This pre-CPU smoke is non-cohort evidence; the 90-second gate applies to the accepted
      after-cohort p95.
- [ ] 3.22 Run one retry-free exact-SHA `IntegrationBenchmark` smoke with the final harness before
      spending the acceptance cohorts. Require a current template, successful outcome-bearing
      teardown, exact runner markers, and zero ownership, deadlock, queue-drop, connection-headroom,
      process-residue, or database-residue failures.
- [x] 3.23 Diagnose the first exact-SHA smoke without retrying victims: remove database cleanup from
      async `on_exit` handlers and statically restrict async teardown callbacks; use the rollup
      trigger's existing transaction-local bypass for async Sandbox owners so device writers do not
      queue on `device_inventory_counts['total']`; prove allowed-child inheritance, rollback
      non-leakage, actual trigger suppression, and trigger-enabled serial rollup coverage.

## 4. BuildBuddy and release qualification
- [x] 4.1 Add a separate BuildBuddy action for the focused heavy lifecycle, triggered on pushes to
      `staging`, a nightly UTC schedule, and release tags, with classic GitHub status context
      `LargeIngestionGate`.
- [x] 4.2 Reuse the guarded template, fixture TLS, credential scoping, local non-cached TestRunner,
      unique run-id, and outcome-bearing teardown contracts; do not duplicate or restore a retired
      fixture environment bridge.
- [x] 4.3 Give the release workflow explicit `statuses: read` permission and poll the exact tag
      commit's classic `LargeIngestionGate` status for at most 30 minutes before publication,
      accepting only the newest matching record when it is successful and its parsed HTTPS URL has
      host exactly `carverauto.buildbuddy.io` plus a nonempty invocation id.
- [x] 4.4 Atomically add a permanent `build/ci/large_ingestion_gate_contract.v1` introduction marker
      with the complete Bazel-owned, unit-tested release qualifier and workflow wiring, covering
      ancestry-based applicability, complete
      marker-bearing trees, missing/repeated introduction evidence, divergent histories,
      newest-status selection, BuildBuddy URL validation, pagination, and timeout/error behavior.
- [x] 4.5 Add static workflow tests covering the trigger set, focused targets, retry policy,
      pull-request `-large_ingestion_test` filter, credential boundaries, teardown, qualifier
      invocation, and release-status context.
- [x] 4.6 Keep historical tag retries compatible only when the immutable release commit is a strict
      ancestor of the marker's first addition on `origin/staging` first-parent history. Fail closed
      when the introduction is an ancestor of a markerless release, when the commits are divergent,
      when introduction evidence cannot be established, or when a marker-bearing tree lacks the
      target or action; require a manually backfilled BuildBuddy result rather than a bypass for
      applicable commits.

## 5. Measurement, balancing, and acceptance
- [ ] 5.0 Lock the corrected before/after cohort identities, clock boundaries, flags, calculations,
      evidence schema, connection headroom, and pass/fail goals in `benchmark.md`; retain the first
      frozen-before candidate only as invalidated harness history.
      Status: the schema and pass/fail contract are written, but the corrected exact-SHA cohort
      identities and authoritative clock rows are not populated yet.
- [ ] 5.1 Add and test a Bazel-owned connection observer plus an instrumentation-only,
      non-merging `IntegrationBenchmark` action; prohibit built-in slowest reporting in timed/gating
      actions, emit the effective runner configuration, repair history so the corrected
      instrumentation commit is the direct parent of the first behavior change, and keep the
      harness identical at the final revision.
      Status: the observer, action, and static contracts are implemented; direct-parent history
      repair and the final identical-harness freeze remain cohort prerequisites.
- [ ] 5.2 Capture per-shard duration, maximum sampled fixture/run connections (with unrelated
      fixture sessions retained in the fixture-wide count), live total server connection capacity,
      observer-session exclusion, UTC sample window, pre-teardown zero samples, and the
      ordinary lifecycle through outcome-bearing teardown with Bazel and workflow retries disabled;
      use literal database-prefix matching rather than unescaped SQL `LIKE`, preflight migrations
      outside the clock, capture the end timestamp immediately when teardown returns, and require
      runner markers proving before `max_cases: 1`, intermediate `max_cases: 2`, final async lane
      `max_cases: 8`, final serial lanes `max_cases: 1`, topology/lane, scheduler count, Repo pool
      size 12, trace off, and timeouts on.
      Status: local directional runs exercise the collector and invariants, but the authoritative
      BuildBuddy cohort table is intentionally still empty.
- [ ] 5.3 After tasks 5.6 and 6.1--6.3 pass on the final candidate, run alternating exact-SHA cohorts
      until both revisions have 20 consecutive successful lifecycles; retain all failed sequence
      rows and require zero ownership errors, deadlocks, leaked database processes, leaked
      databases, or retry-masked failures.
- [x] 5.4 Run the historical separately labeled serial/non-cohort slow-case profiling wave after the
      release-gate extraction, async promotion, and 258-identity allocator correction; recompute
      auditable relative source weights, assign sources by deterministic least-estimated-load
      sum-only partitioning, then require slowest/fastest non-empty shard skew no greater than 1.5.
      Retain this as historical evidence only: its older local runner mode and membership do not
      supply final source weights. Completed task 3.19 supersedes that historical map with the
      database-free exact-selected-identity rule and separately proves the final concurrency-aware
      fixed-resource placement and deterministic source/identity membership.
- [ ] 5.5 Demonstrate nearest-rank p95 at or below 90 seconds and at least 50% below the accepted
      before p95 over the accepted 20-run after cohort,
      including the existing SRQL/other integration targets and excluding only the
      `large_ingestion_test`-tagged heavy release-qualification target (including cold bootstrap),
      report whether the relative p95 improvement reaches the 60% stretch target, with the
      fixed one-async-plus-seven-serial-lanes topology, explicit identical CPU allocation, and Repo
      pool size 12 per BEAM.
- [ ] 5.6 Run the focused large-ingestion lifecycle repeatedly, verify successful default-branch
      status publication, and prove teardown removes every matching database.

## 6. Repository verification
- [x] 6.1 Reconcile implementation with `complete-config-manager-adoption`,
      `route-bazel-cache-through-shared-edge`, and `add-srql-fixture-cert-manager-tls`.
      Status: merged current `github/staging` through `70a88c91f9`; the latest core sources,
      `interface_ip_alias_test.exs`, `interface_alias_cap_test.exs`, and
      `candidate_device_address_test.exs`, are real-ExUnit-verified load-only sources, and the
      modified `mapper_role_heuristic_test.exs` remains load-only. The exhaustive disposition now
      contains 786 source rows and 283 selected modules.
- [ ] 6.2 Run focused Elixir support tests, Rust lifecycle tests, Bazel configuration tests, the
      async target, every selected serial target, and the large-ingestion release gate.
      Status: focused/static contracts and local target-equivalent shard/heavy runs are green; the
      exact guarded Bazel all-shard and heavy lifecycle sequence remains pending.
- [ ] 6.3 Run `make lint`, `make test`, and `git diff --check`.
      Status: `make test` is green with all 200 targets passing and `git diff --check` is green.
      `make lint` reports zero Go issues, then the locally installed SwiftLint aborts while loading
      `sourcekitdInProc.framework`; the complete lint target remains pending in a compatible runner.
- [x] 6.4 Run `openspec validate parallelize-core-integration-tests --strict`.
