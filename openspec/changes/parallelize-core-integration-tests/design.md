## Context
ServiceRadar core currently has two levels of database isolation:

1. Bazel partitions all core integration test files across eight `ex_unit_test` targets.
2. Each target receives a separately cloned PostgreSQL database (`s0` through `s7`), and each
   `ServiceRadar.DataCase` test starts a rollback-only Ecto SQL Sandbox owner.

The first level prevents independent BEAM VMs from deadlocking against one shared database. The
second level already has the semantics needed for concurrent transactional tests inside one BEAM,
but the runner fixes `max_cases: 1` and nearly every DataCase module is declared `async: false`.

The sampled critical path shows why the next optimization belongs inside the existing shards:

| Measurement | Observed value |
| --- | --- |
| Recent successful PR integration phases | 2m21s, 2m26s, 2m27s, 2m54s, 4m22s |
| Typical pre-test fixture setup and provisioning | 15-20s |
| Stable slowest shard | 107-113s |
| Stable fastest shard | 53-56s |
| Current slowest/fastest skew | about 2.0 |
| 50,000-device router ingestion test | about 47.2s |
| Identifier-cardinality release gate | 500 devices across three ingest rounds |
| Template clone per database | about 0.7s |
| Fixed BEAM cost per additional shard | about 36s |

The current test inventory also contains known concurrency blockers:

- 17 modules use `sandbox: :unboxed`.
- Three modules issue 11 `TRUNCATE` statements.
- Other modules perform DDL, refresh database-global objects, mutate `Application` configuration,
  use NATS, or coordinate through globally named/supervised processes.

These cases are not made safe merely by opening another transaction.

### Marvin's Diesel pattern and the Ecto equivalent
Marvin's example calls Diesel's `begin_test_transaction()` on a newly established connection. The
test performs all writes through that connection, and Rust's drop lifecycle implicitly abandons
the still-open transaction so PostgreSQL rolls it back.

ServiceRadar already implements the same rollback boundary in BEAM terms:

| Diesel/Rust | ServiceRadar/Ecto |
| --- | --- |
| one `PgConnection` per test | one SQL Sandbox owner and checked-out connection per test |
| `begin_test_transaction()` | `Sandbox.start_owner!(Repo, shared: false)` |
| all queries use that connection | the test process and explicitly allowed children use that owner |
| connection drop abandons transaction | `Sandbox.stop_owner(owner)` rolls back and returns connection |

The implementations are not identical because Elixir tests frequently involve several BEAM
processes. Ecto therefore requires connection ownership routing. A child process must either be
tracked through caller ancestry or receive an explicit `Sandbox.allow/4`; a globally supervised
process cannot safely be allowed to two concurrent test owners.

### Current owner teardown is not async-safe
`ServiceRadar.TestSupport.stop_repo_owner/1` currently drains application-global processes and then
calls `Sandbox.mode(Repo, :manual)` after every owner stops. Ecto documents that changing the pool
to `:manual` checks in all existing connections. That cleanup is necessary after a serial shared
owner, but it would terminate other tests' live transactions if two non-shared owners ran at once.

The implementation must split teardown behavior:

- a serial/shared owner may drain the application-global workers it used, stop the owner, and
  restore the pool from shared to manual mode;
- an async/non-shared owner stops only its own owner and must not change global sandbox mode or
  drain shared application processes.

## Goals / Non-Goals

### Goals
- Reduce the warm ordinary BuildBuddy database-integration lifecycle p95 to 90 seconds or less.
- Preserve transaction rollback and data invisibility between concurrent tests.
- Make async eligibility explicit and reviewable rather than inferred from a broad runner flag.
- Preserve coverage while removing the large-ingestion release gate from ordinary pull requests.
- Keep the current eight database shards, template clone path, TLS posture, credential scope, and
  cleanup guarantees.
- Prove stability with at least 20 consecutive CI-equivalent runs before considering a higher
  concurrency cap.

### Non-Goals
- Make every integration module async.
- Let a transaction sandbox pretend that DDL, NATS, application configuration, ETS, registries, or
  global supervisors are test-local.
- Add more database shards, Repo connections, or fixture capacity in the first rollout.
- Change SRQL fixture tests, which already have separate database contracts and are not the
  measured critical path.
- Solve cold repository build times.

## Architecture

The ordinary pull-request path remains a two-level bounded topology:

```text
BuildBuddy PR action
  -> prepare one current template
  -> clone s0..s7 databases
  -> run eight Bazel shard targets in parallel
       -> one BEAM per shard
       -> at most two async ExUnit modules per BEAM
       -> each active test case owns one rollback-only connection
       -> serial modules run with shared ownership and no overlap in that BEAM
       -> fixed shared-external-resource modules are pinned to one designated shard
  -> teardown every database for the run prefix
```

The heavy path is source-separated:

```text
BuildBuddy default-branch/nightly/release action
  -> prepare the same template contract
  -> clone one <run>_large_ingestion database
  -> run only //elixir/serviceradar_core:large_ingestion_release_gate
  -> teardown the run prefix
  -> publish a named commit status consumed by release qualification
```

## Decisions

### Decision: Keep eight outer shards and add a cap of two inside each BEAM
The initial integration-only `max_cases` is 2. ExUnit only schedules modules declared
`async: true` concurrently; `async: false` modules retain the serial barrier semantics within their
BEAM. The cap is set by the Bazel integration target environment and parsed by `test_helper.exs`,
with invalid, missing, or non-positive values failing closed for the integration target.

The value is deliberately conservative:

- eight shards already create up to eight BEAMs and eight Repo pools;
- a cap of two permits progress while bounding the additional active sandbox connections;
- the fixture currently allows 200 connections and the initial change does not increase shard
  count or pool size;
- a larger cap is a later measured change, not an automatic use of all runner schedulers.

The implementation will expose one checked-in Starlark constant for this initial cap so generated
targets cannot drift. A configuration test will assert that every core integration shard receives
the same value.

### Decision: Async is an explicit module opt-in
The runner does not attempt to infer safety. A module remains `async: false` unless it satisfies all
of these conditions:

- every database mutation can remain inside the test's sandbox transaction;
- it does not use `sandbox: :unboxed`, DDL, `TRUNCATE`, advisory-lock behavior requiring distinct
  real connections, materialized-view refresh, or committed cross-connection visibility;
- it does not mutate `Application` configuration, persistent terms, global ETS, logger handlers,
  time-zone/global process state, or other VM-global state;
- it does not publish to or consume from NATS or another shared external service;
- it does not depend on a globally named or application-supervised process performing database
  work on its behalf;
- any child process that queries the Repo is test-owned, supervised for the test lifetime, and
  explicitly routed to the test's sandbox owner;
- its identifiers are unique where PostgreSQL constraints or non-transactional infrastructure
  require uniqueness.

The first implementation pass audits transaction-only CRUD/query modules and converts only that
reviewed set. Remaining modules stay serial without being treated as migration failures.

### Decision: Make sandbox ownership locally composable
`checkout_repo!/1` continues using `Sandbox.start_owner!/2`, with `shared: not context[:async]`.
It also rejects `context[:async] && context[:sandbox] == :unboxed` before changing pool state.

The returned setup context includes the sandbox owner. `ServiceRadar.DataCase` exposes a
project-owned helper that calls `Sandbox.allow(ServiceRadar.Repo, self(), child_pid)` and checks
the result. `:ok` and `{:already, :allowed}` are accepted; `{:already, :owner}`, `:not_found`, and
unexpected results fail with a useful ownership error. Async tests use the helper only for
test-owned children. The owner remains alive through `on_exit`, and children must be stopped before
the owner is stopped.

The owner teardown has two paths:

- `shared: false`: stop that owner only;
- `shared: true`: drain the existing application-global workers, stop the owner, then restore
  manual mode.

No async teardown may call `Sandbox.mode/2`. This prevents one test from checking in every other
test's connections.

The current `with_repo_owner/1` shared-owner helper cannot enforce that rule because it receives no
ExUnit context. It is replaced by `with_repo_owner(context, fun)`, which requires the caller's test
context and rejects `context[:async]` before starting an owner or changing mode. Removing the
context-free entry point makes an async call a compile-time/API migration rather than an accidental
path back to shared mode.

### Decision: Keep serial exception lanes at the scope of the shared state
Serial tests use `async: false` and may use shared sandbox ownership when their cooperating
processes cannot receive explicit allowances. Tests tagged `sandbox: :unboxed` remain serialized
inside their BEAM and must clean committed state explicitly.

That module-level flag is sufficient for state shared only by one shard database or one BEAM. It is
not sufficient for NATS streams, fixed subjects, or another fixture-global resource because the
eight Bazel targets are separate OS processes. Tests that use a fixed external namespace are pinned
to one designated existing shard (initially `s7`) and remain `async: false`. The other seven shards
must contain no test using that fixed resource. A test may remain outside the designated shard only
when its external resource name is unique per test/run and its cleanup is scoped to that name.

The designated lane does not create a ninth database or BEAM. It reserves a source class within the
existing `s7` target, and the partitioner may add transaction-isolated sources to that shard for
runtime balance. ExUnit completes all async modules before its synchronous phase, so the
fixture-global modules do not overlap another module in `s7`; the source-class guard ensures no
other shard can overlap them through the same external resource.

| Behavior | Required scope | Reason |
| --- | --- | --- |
| DDL, extension/graph changes, materialized-view refresh | `async: false` in any shard | Each outer shard has its own database, but catalog locks are not test-transaction local |
| `TRUNCATE` or committed cleanup | `async: false` in any shard | Cross-test locks and visibility conflict inside one database |
| `sandbox: :unboxed` | `async: false` in any shard | It disables the rollback boundary |
| fixed NATS stream/subject or another fixture-global name | `async: false` in designated `s7` only | The external state is shared across BEAMs |
| uniquely named external resource with scoped cleanup | Audited case; async only with explicit proof | Isolation comes from the unique namespace, not Ecto |
| `Application.put_env/delete_env`, persistent term, global logger state | `async: false` in any shard | State is shared by one BEAM |
| globally named/application-supervised database clients | `async: false` in any shard | One process cannot belong to two sandbox owners |
| real multi-connection lock or notification tests | `async: false` and unboxed in any shard | Sharing one sandbox connection invalidates the behavior under test |

A runtime guard covers the most dangerous invalid combination (`async: true` plus unboxed mode).
Code review and checked-in partition tests cover the broader semantic classification, including the
single-shard external-resource source list; a grep heuristic is not treated as proof of safety.

### Decision: Source-separate the large-ingestion gates
The 50,000-device router test and the 500-device, three-round identifier-cardinality gate move out
of the ordinary `ALL_TEST_SRCS` glob into dedicated release-gate sources and an explicit
`large_ingestion_release_gate` Bazel target. The target has:

- only the large-ingestion release-gate sources plus declared runtime data;
- the same compiled application dependency as the core integration shards;
- `//build:run_id_file` as declared data, `SERVICERADAR_ONLY_INTEGRATION=1`, and
  `SERVICERADAR_TEST_DB_SHARD=large_ingestion`;
- `test/db/integration_env.exs` loaded before the Elixir test configuration loader, matching the
  ordinary shard targets;
- a dedicated `large_ingestion` database suffix derived from that declared run-id file;
- the shared-fixture compatibility guard;
- `integration_test` and `large_ingestion_test` Bazel tags for discovery and policy;
- local, non-cached `TestRunner` execution under the guarded lifecycle.

The ordinary unit and integration source sets exclude the release-gate directory. This physical
source boundary, not `exclude: :large_ingestion`, guarantees that positive ExUnit includes cannot
pull the test back into one of the eight shard targets.

The dedicated target retains `integration_test` so the ordinary unit wildcard continues excluding
it, and adds `large_ingestion_test`. The pull-request integration wildcard changes to
`integration_test,-large_ingestion_test,-acceptance_test`. This second boundary prevents Bazel from
selecting the dedicated target itself when the workflow asks for all integration-tagged targets.
Source separation protects ExUnit selection inside the shards; the negative Bazel target tag
protects wildcard target selection.

`build/integration_shards.bzl` exports the dedicated suffix separately from `s0..s7`.
`provision_db` continues cloning exactly the eight PR databases; a focused
`provision_db_large_ingestion` target declares the same run-id file, fixture configuration, and
core migration filegroup as the ordinary provision targets, and supplies only the dedicated suffix
through `SERVICERADAR_TEST_DB_SHARDS`. It clones only the heavy-gate database. Teardown already owns
the entire run prefix and removes either shape.

The production router workload remains 50,000 devices by default and the cardinality workload
remains 500 devices across three rounds. A lower local router override may remain available for
developer diagnosis, but CI release qualification cannot lower either workload.

### Decision: Give the heavy test an independent BuildBuddy action
`buildbuddy.yaml` gains a separate action that uses the same runner pool, fixture setup, template
check, local database `TestRunner`, credential scoping, and outcome-bearing teardown as the PR
lifecycle. It triggers:

- on pushes to `staging`;
- nightly through a BuildBuddy `schedule` cron; and
- on release tags.

The action runs only the focused large-ingestion provision and test targets, not all eight PR
shards. The action name and classic GitHub commit-status context are
`LargeIngestionGate`. BuildBuddy's linked GitHub App, not a credential passed into the Bazel action,
posts that status for the exact workflow commit with a BuildBuddy target URL.

The release workflow already resolves the immutable tag commit. After Bazelisk and the authenticated
remote configuration are available, but before Cosign, ORAS, artifact builds, or publication, it
runs a Bazel-owned Python qualifier. The executable receives the exact release SHA, repository,
fetched `origin/staging` ref, and GitHub token environment-variable name. It invokes `gh api`
without a shell, polls GitHub's commit status API for context `LargeIngestionGate` on that exact
SHA, and accepts only `success` whose parsed URL has HTTPS scheme, host exactly
`carverauto.buildbuddy.io`, and a nonempty `/invocation/<id>` path. Classic statuses are append-only,
so each poll filters the exact context, orders matching records by creation time and status id, and
evaluates only the newest record. An older success cannot mask a newer pending, error, or failure.
The workflow waits at most 30 minutes for a tag-triggered action that is still pending or not yet
visible, and fails closed on timeout, API error, malformed data, error, or failure.

One current successful status for the exact SHA is sufficient whether produced by the `staging` push,
nightly schedule, or tag trigger; the policy proves the tested source revision, not which event
started the run. The implementation commit adds a permanent
`build/ci/large_ingestion_gate_contract.v1` marker in the same tree as the target, action, and
qualifier. The qualifier requires the release commit to be an ancestor of the fetched base, the
base tree to contain the exact v1 marker, and exactly one marker-addition commit on
`origin/staging`'s first-parent history. Missing, repeated, shallow, or malformed introduction
evidence fails closed. It then classifies an immutable release tree as follows:

- marker present: the target and action MUST also be present, and status enforcement applies;
- marker absent and the release commit is a strict ancestor of the introduction commit: the tag is
  historical and retains the existing recovery behavior;
- marker absent when the introduction commit is an ancestor of the release commit: fail as
  contract deletion or corruption (equality is included and therefore cannot bypass);
- marker absent when neither commit is an ancestor of the other: fail closed rather than treating
  a divergent side-branch commit as historical;
- missing introduction evidence, git errors, or a marker without both contract halves: fail closed.

This ancestry boundary prevents deleting any contract file from turning a future tag into an
apparently historical one. A qualifying commit can be backfilled by manually executing the same
BuildBuddy action for that revision, but it cannot bypass the test. Pure unit tests cover the
applicability state machine, newest-status selection, target-URL validation, and deadline behavior;
the workflow contract test proves the release job invokes the Bazel target at the required point.

This keeps the expensive coverage frequent and release-blocking without charging every developer
change. It also keeps tests on BuildBuddy, while GitHub remains the collaboration and release host.

### Decision: Rebalance after changing the workload
The current partition gives heavy files priority because file-count round robin did not balance
runtime. Once both release gates are extracted and some modules overlap, those weights are stale.

After the async set is stable, each shard is run with `SERVICERADAR_TEST_SLOWEST` reporting enabled.
That output is intentionally truncated, so it supplies ranked slow-case hints rather than a complete
per-file timing census. The checked-in heavy-source ordering is updated from repeated slow-case
appearances together with complete per-shard action durations; the evidence does not invent timing
values for files that were not emitted.

Template preparation and any migration run in a separate preflight before measurement. The
end-to-end measurement starts immediately before fixture configuration is materialized and its end
timestamp is captured immediately when teardown returns, before observer shutdown/wait overhead.
The in-clock template check is current-only; a newly pending result is retained as non-cohort and
cannot migrate inside the timing window. The preceding full-build step must have warmed the exact
Bazel configuration. The measured ordinary wave includes
every target selected by the pull-request integration filter (the eight core shards, the
designated shared-resource lane within them, SRQL fixture targets, and other existing integration
targets) and excludes only the source-separated large-ingestion gate. Over 20 consecutive runs,
p95 is the nearest-rank 19th ordered value.

Acceptance requires:

- warm integration lifecycle p95 at or below 90 seconds;
- 20 consecutive retry-free before attempts and 20 consecutive retry-free after attempts under an
  identical exact-SHA harness;
- no shard more than 1.5 times the runtime of the fastest non-empty shard in any accepted after run;
- sampled run-scoped connections at most 144 and fixture-wide connections at most
  `floor(live usable client slots * 0.90)` in every accepted after run;
- two consecutive zero run-scoped samples before teardown and no database under the run prefix
  after teardown; and
- no sandbox ownership error, deadlock, leaked task, leaked database, or retry-masked failure in
  either accepted cohort.

The full measurement protocol, controlled before/after cohort identity, connection headroom, raw
evidence schema, and calculation rules are normative for this change and live in `benchmark.md`.

The acceptance runs use `--flaky_test_attempts=1`. Retries would hide the instability this change is
intended to detect.

### Decision: Preserve fixture and configuration boundaries
This proposal changes scheduling and test ownership only. It does not change:

- the guarded `sweep -> prepare -> conditional migrate -> provision -> suite -> teardown`
  lifecycle;
- live CA material, `sslmode=verify-full`, or server-name verification;
- local, non-cached database `TestRunner` actions;
- credential forwarding only to explicit integration profiles;
- the template migration source or configuration-manager ownership.

`complete-config-manager-adoption` overlaps `buildbuddy.yaml` and fixture environment setup. The
implementation must apply against whichever configuration transport is current and must not
restore a retired environment bridge. Bazel targets consume the final contract rather than owning
how secrets are materialized.

## Failure Behavior
- An invalid integration concurrency value fails before ExUnit starts.
- `async: true` with `sandbox: :unboxed` raises with a message directing the module to the serial
  lane.
- A child process that is not allowed receives the normal sandbox ownership failure; tests must
  use the project helper rather than switching the Repo to shared mode.
- A failure in either ordinary or heavy integration tests still runs teardown for the same run id.
- A teardown failure fails an otherwise green action.
- A missing or failed heavy-gate commit status blocks release publication.
- A historical release tag whose commit predates the permanent gate-contract marker reports the
  gate as not applicable. Marker removal at or after the introduction commit, or a marker-bearing
  tree missing the heavy target or BuildBuddy action, fails closed.
- Scheduled heavy-gate failure does not retroactively fail a merged PR, but it creates a visible
  failing status on the default-branch commit and prevents that commit from qualifying for release.

## Rollout Plan
1. Add focused tests for owner teardown, async/unboxed rejection, child allowance, concurrency
   configuration, and source separation while the runtime cap remains one.
2. Split the large-ingestion source and add its focused database lifecycle and BuildBuddy action.
   Verify ordinary PR target queries cannot reach the heavy source.
3. Refactor shared versus non-shared owner teardown, pin fixed shared-external-resource tests to
   the designated outer shard, and audit the first transaction-only modules.
4. Set the integration cap to two and enable `async: true` only for the audited set.
5. Run 20 consecutive CI-equivalent lifecycles with retries disabled, record per-shard timings and
   peak database connections, and repair any classification errors.
6. Rebalance the shard heavy-source hints and verify the performance and skew thresholds.
7. Land the marker, complete qualifier, and workflow wiring atomically. After merge, verify the
   `staging` push status before tagging when practical; otherwise the tag-triggered action must
   satisfy the same exact-SHA poll within its 30-minute deadline.

Rollback sets the cap back to one and changes the newly async modules back to `async: false`.
The heavy test remains source-separated and continues running in its dedicated gate; rollback does
not reintroduce it into every pull request.

## Risks / Trade-offs
- Async eligibility requires semantic review. Static matching can identify likely blockers but
  cannot prove that a module never reaches a global process.
- A new test can accidentally use a fixed external resource outside the designated shard. A
  checked-in source-classification test and review rule make that failure visible; resource names
  that are derived dynamically still require semantic review.
- Two tests can still contend on schema-wide PostgreSQL locks even with separate transactions.
  Such a module must move back to the serial lane; the stress gate is designed to expose this.
- A test-owned child may query before an allowance is installed. Async conversions must control
  child startup or use caller ancestry so database work cannot race the allowance.
- The eight Repo pools already reserve more connections than the typical active query count. The
  initial cap does not change pool sizes, but acceptance records peak fixture connections and stops
  rollout if the existing 200-connection ceiling loses operational headroom.
- The separate heavy action adds default-branch compute. It removes that compute from every PR and
  runs only one BEAM/database, so total developer latency falls while coverage remains frequent.
- Release status enforcement introduces a dependency on the BuildBuddy action completing. The
  release workflow must report the pending/failed context clearly and time out rather than publish
  without evidence. The permanent introduction marker is part of the compatibility contract and
  must never be removed; checked-in behavior and workflow tests make deletion fail closed.

## Alternatives Considered

### Increase from eight to sixteen Bazel shards
Rejected for the first iteration. Every extra shard repeats about 36 seconds of BEAM setup,
increases Repo pools and fixture databases, and cannot divide a single 47-second test.

### Raise `max_cases` for every module
Rejected. `async: false` modules would still serialize, while changing all modules to async would
race DDL, NATS, application configuration, and global supervisors.

### Give every test file its own database
Rejected. Template cloning is cheap, but BEAM startup and runfiles staging are not. The outer shard
count is already near the useful point of diminishing returns.

### Use unboxed transactions like ordinary tests
Rejected. Unboxed mode exists specifically for behavior that cannot run inside the sandbox
transaction. It commits and therefore cannot provide Diesel-like implicit rollback.

### Rely on the `:large_ingestion` exclude tag
Rejected. Positive ExUnit includes take precedence over excludes. Source separation is the chosen
structural guarantee that ordinary shard targets cannot compile or select the heavy test, paired
with a negative Bazel tag filter so the wildcard cannot select its dedicated target.

## Open Questions
- None. The isolation classes, initial cap of two, source-separated heavy gate, BuildBuddy schedule,
  release qualification, and acceptance thresholds are the approved starting design.
