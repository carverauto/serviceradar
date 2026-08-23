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
| Repeated BEAM startup/source-load work per shard | about 36s aggregate work, mostly overlapped |

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

### Why the first async pass was insufficient
The first complete green treatment finished in 259.00 seconds. Source separation, focused test
work reduction, and sum-weighted placement reduced a later green wave to 203.02 seconds with
slowest/fastest skew 1.444. That is a useful 21.6% improvement, but it is not evidence of broad
database concurrency: only two of the 222 ordinary selected DataCase modules are `async: true`, and
those two sources are assigned to different shards.

The remaining 220 serial declarations include both genuine shared-state blockers and ordinary
transaction-only modules hidden behind redundant `setup_all` calls to `start_core!`. ExUnit
schedules modules, not individual test functions, concurrently. The continuation therefore has to
classify the entire ordinary DataCase inventory, promote transaction-isolated modules, and split
mixed files whose small unsafe portion currently serializes a large safe portion.

## Goals / Non-Goals

### Goals
- Reduce the warm ordinary BuildBuddy database-integration lifecycle p95 by at least 50% versus
  the controlled before cohort and to 90 seconds or less; report 60% as the stretch result.
- Preserve transaction rollback and data invisibility between concurrent tests.
- Make async eligibility explicit and reviewable rather than inferred from a broad runner flag.
- Give every selected ExUnit module an explicit checked-in disposition and account for every
  zero-selected source: promoted async, quarantined serial with concrete evidence, or load-only.
- Preserve coverage while removing the large-ingestion release gate from ordinary pull requests.
- Keep the current eight database shards, template clone path, TLS posture, credential scope, and
  cleanup guarantees.
- Prove one complete retry-free, observed eight-shard safety wave at cap two before advancing to
  cap four, then reserve the 20-run exact-SHA cohorts for final acceptance.

### Non-Goals
- Make every integration module async.
- Let a transaction sandbox pretend that DDL, NATS, application configuration, ETS, registries, or
  global supervisors are test-local.
- Add more database shards, Repo connections, or fixture capacity in the first rollout.
- Collapse the ordinary suite into one BEAM without controlled evidence; unavoidable serial work
  would accumulate instead of being distributed across outer shards.
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
       -> cap two during the migration safety wave, then at most four async modules per BEAM
       -> each active test case owns one rollback-only connection
       -> serial modules run with shared ownership and no overlap in that BEAM
       -> fixed shared-external-resource modules are pinned to one designated shard
  -> teardown every database for the run prefix
```

The heavy release-qualification path is source-separated:

```text
BuildBuddy default-branch/nightly/release action
  -> prepare the same template contract
  -> clone one <run>_large_ingestion database
  -> run only //elixir/serviceradar_core:large_ingestion_release_gate
       -> two full-strength ingestion/cardinality suites
       -> one intact two-pass cold database-bootstrap suite
  -> teardown the run prefix
  -> publish a named commit status consumed by release qualification
```

## Decisions

### Decision: Stage in-shard concurrency from two to four
ExUnit only schedules modules declared `async: true` concurrently; `async: false` modules retain
the serial barrier semantics within their BEAM. The cap is set by the Bazel integration target
environment and parsed by `test_helper.exs`, with invalid, missing, non-positive, or above-pool
values failing closed for an integration target.

The rollout has two explicit states:

- migration safety wave: all eight shards use `max_cases: 2`, trace is off, timeouts are enabled,
  retries are disabled, and the connection observer covers provision through teardown;
- final treatment: only after that wave has zero ownership errors, deadlocks, checkout drops,
  leaked processes, or database residue and retains connection headroom, all eight shards advance
  together to `max_cases: 4` and repeat the same safety gate.

Eight shards continue to create eight BEAMs and eight Repo pools, each with the unchanged pool size
of 12. Raising the scheduler cap does not raise configured connection capacity; it allows more
audited modules to contend for the existing pool. A cap-four failure is fixed by correcting the
classification, ownership routing, or workload—not by retries, a larger pool, or relaxed
timeouts. The final accepted runner marker is `max_cases=4 trace=false timeouts=enabled`.

One checked-in Starlark constant defines the current ordinary cap so generated targets cannot
drift. Configuration tests freeze cap two during the safety commit and cap four in the final
treatment commit.

### Decision: Control workflow CPU and Repo capacity independently
The BuildBuddy actions currently request memory and disk but omit CPU. The workflow executor's
default task floor is 2,000 milli-CPU even though the runner pod requests 12 CPUs and permits 16,
while the current marker does not report `System.schedulers_online()`. Local waves explicitly
limited each BEAM to two schedulers, but workflow scheduler count remains unknown until the expanded
marker lands. At the same time, test Repo pool size defaults from `System.schedulers_online()` with
a floor of 12 and cap of 16. Raising workflow CPU without an explicit database-pool value would
therefore change two variables at once.

Before the final latency cohorts, five attempts per arm alternate same-revision diagnostics for
explicit 2-CPU and 12-CPU workflow allocations. Both arms pin
`SERVICERADAR_TEST_DATABASE_POOL_SIZE=12`, run the same eight-shard cap-four source topology, and
use identical build warmth, lifecycle, observer, retries, trace, and timeout settings. The runner
marker includes scheduler count, integration cap, effective Repo pool size, topology, and lane.

An arm is selectable only when all five attempts pass every safety/headroom gate. If neither arm is
selectable, rollout stops; if only one is selectable, it wins. If both are selectable, 12 CPUs wins
only when its untrimmed five-run median lifecycle is at least 10% lower than the 2-CPU median;
otherwise the deterministic tie/default is 2 CPUs. The winner becomes the explicit request in the production `BazelCI` action
and in both before and after authoritative benchmark harnesses. This is required so the accepted
p95 measures the capacity developers actually receive on pull requests.
CPU sizing diagnostics are labeled non-cohort; CPU allocation is never changed in only one
accepted revision, and Repo pool size stays 12 throughout this proposal.

### Decision: Make suite startup concurrency-neutral
`test_helper.exs` starts the application once before ExUnit schedules integration modules. It owns
the explicit suite-global choice to make audit writes synchronous in tests and establishes manual
Sandbox mode before test owners are created.

`TestSupport.start_core!/1` without the explicit `:synchronous_audit_writes?` option becomes an
idempotent ensure-started operation: it MUST NOT call `Application.put_env/3` or otherwise alter
VM-global configuration. Passing the explicit option remains available only to suite/bootstrap
code that runs before concurrent scheduling. Promoted modules remove redundant no-option
`setup_all` startup blocks rather than racing repeated application setup.

A focused regression sets the audit-writer value, calls no-option startup, and proves the value is
unchanged. A separate assertion proves `test_helper.exs` supplies the explicit synchronous setting.
The async-source audit rejects module-local Application mutation and redundant `start_core!` calls.

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

The initial two-module pass is recorded as migration evidence, not as completion. Every selected
ExUnit module must now have one checked-in disposition, and every source in the ordinary glob must
be accounted for. This includes direct DataCase and non-DataCase modules so placement and layout
diagnostics do not silently treat already-async jobs as serial:

- transaction-only modules are changed to `async: true`;
- mixed modules are split so the transaction-only module/file is async and only the unsafe cases
  remain serial;
- serial quarantine records the exact blocker and its required scope;
- a module becomes eligible after fixed identifiers, handlers, registries, caches, or child
  processes are made unique/test-owned and cleanup is scoped to that exact namespace.

The first broad wave promotes the fully audited seeder reconciliation, dispatcher delivery,
dispatcher grouping, action redemption, delivery isolation, suppression dedupe, DIRE remediation,
sweep-results flow, and agent-config credential-delivery modules. The next wave splits or
normalizes endpoint inventory races, dispatcher routing PubSub assertions, dispatcher edge registry
keys, agent-gateway release signing, dispatcher telemetry handlers, sync identifiers/caches,
identity telemetry, remote-access session races, and agent-command-bus global processes. Each wave
runs through the cap-two safety gate before the final cap-four treatment.

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

The shared-owner path legitimately multiplexes cooperating processes through one sandbox owner,
so bursts can queue at that ownership proxy even while the Repo pool still has capacity. The
default 50 ms queue bound is too short for that supported path: the focused regression observes a
waiting query being dropped after roughly 984 ms under sustained concurrent checkouts. The test
Repo therefore uses finite 1,000 ms `queue_target` and `queue_interval` defaults, preserves the
existing environment overrides and pool sizes, and must pass both that focused RED/GREEN regression
and a complete eight-shard wave. This is a measured bound, not a general timeout ratchet; it must
not be raised toward the 20-second checkout timeout to conceal starvation or lost ownership.

The current `with_repo_owner/1` shared-owner helper cannot enforce that rule because it receives no
ExUnit context. It is replaced by `with_repo_owner(context, fun)`, which requires the caller's test
context and rejects `context[:async]` before starting an owner or changing mode. Removing the
context-free entry point makes an async call a compile-time/API migration rather than an accidental
path back to shared mode.

### Decision: Keep serial exception lanes at the scope of the shared state
Serial tests use `async: false` and may use shared sandbox ownership when their cooperating
processes cannot receive explicit allowances. Tests tagged `sandbox: :unboxed` remain serialized
inside their BEAM and must clean committed state explicitly.

Tests whose assertion depends on a real multi-transaction race cannot use boxed shared ownership:
that arrangement routes the actors through one database connection and serializes the behavior the
test claims to exercise. The remote-access lock races therefore run unboxed, pin each actor with
`Repo.checkout/1`, prove distinct PostgreSQL backend PIDs are waiting on a separately held lock,
and perform exact failure-safe cleanup. The allocator capacity test follows the same per-test
unboxed rule, with ten concurrent checkouts against the unchanged pool of twelve.

That module-level flag is sufficient for state shared only by one shard database or one BEAM. It is
not sufficient for NATS streams, fixed subjects, or another fixture-global resource because the
eight Bazel targets are separate OS processes. Tests that use a fixed external namespace are pinned
to one designated existing shard (initially `s7`) and remain `async: false`. The other seven shards
must contain no test using that fixed resource. A test may remain outside the designated shard only
when its external resource name is unique per test/run and its cleanup is scoped to that name.

The existing fixed-resource list is re-audited rather than inherited as truth. A row needs concrete
evidence of a mutable shared namespace, cross-BEAM negative assertion, or collision. A read-only
external smoke test such as the Proxmox API source is classified from its actual Repo, VM, and
external behavior and is not pinned merely because it was historically in the list.

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
| Oban-wide cancellation, queue draining, or global plugin/queue mutation | `async: false` in any shard | The operation affects jobs owned by unrelated tests |
| fixed ProcessRegistry keys, PubSub topics, telemetry handlers, or global ETS/cache clears | `async: false` until uniquely namespaced and filtered | Negative assertions and cleanup can observe or erase another test's state |
| unmanaged `Task`/spawned Repo clients | `async: false` until test-owned and explicitly routed | The child has no reliable owner or lifetime boundary |
| real multi-connection lock or notification tests | `async: false` and unboxed in any shard | Sharing one sandbox connection invalidates the behavior under test |

A runtime guard covers the most dangerous invalid combination (`async: true` plus unboxed mode).
Code review, a checked-in async allowlist, and a checked-in serial-quarantine inventory cover the
broader semantic classification, including the single-shard external-resource source list. Every
selected module appears in exactly one disposition row; a source may therefore have multiple rows.
A source is classified async only when every selected ExUnit module it contributes is explicitly
async. A mixed-mode source must be split before source-level placement or hybrid selection; the existing adhoc-scan
NATS and anomaly-profile seeder files are explicit migration cases. Every serial row cites a
concrete operation, resource, or call chain and required scope in the audit; a reason token or grep
heuristic is not treated as proof of safety.

Every async row also carries positive safety evidence. DataCase evidence names the rollback owner
and any child routing; non-DataCase evidence proves there is no direct/indirect unowned Repo work or
VM/external blocker, or names an equivalent explicit owner contract. Existing `async: true` syntax
alone is not evidence.

### Decision: Do not load unit-only sources into integration BEAMs
`ALL_TEST_SRCS` currently feeds every test file into the database-backed shard partition even
though `SERVICERADAR_ONLY_INTEGRATION` selects only `:integration` and `:requires_app` cases. The
inventory therefore covers the entire ordinary source glob. It has one row per selected module at
mode `async` or `serial`, and one sentinel `load_only` row for a source with no selected case. A
`load_only` source is excluded from the ordinary integration source union while remaining in the
unchanged unit-test targets.

This is guarded by behavior rather than tag-text heuristics alone. A manual all-source control and
the pruned-source candidate emit stable selected test identifiers through a project-owned ExUnit
formatter under the same include/exclude configuration; their sets must be exactly equal before
the production shard sources change. Files containing selected and unselected modules are allowed
only when all selected modules have one async mode. Files containing selected modules with mixed
async modes are split. The adhoc-scan NATS and anomaly-profile seeder sources are split so their
selected database/global cases and unrelated async cases are source-addressable.

Placement models module-level selected case weights because ExUnit schedules modules, not files.
It adds a separate common source-load weight for every retained source rather than fabricating
serial case time for `load_only` files. The checked-in ordinary source list equals the distinct
sources having async/serial module rows; the async-safe source list equals sources whose selected
module rows are all async. A checked-in source-to-module job map is exact-checked against the
inventory and a synthetic multi-module source proves its jobs remain independently schedulable.

### Decision: Source-separate heavy release qualification
The 50,000-device router test and the 500-device, three-round identifier-cardinality gate move out
of the ordinary `ALL_TEST_SRCS` glob into dedicated release-gate sources and an explicit
`large_ingestion_release_gate` Bazel target. The cold database-bootstrap test is also explicitly
excluded from `ALL_TEST_SRCS` and included exactly once in this target. The target,
database-suffix, status-context, and marker names are introduced together as permanent stable
contracts; marker ancestry distinguishes genuinely historical releases from later contract
deletion. The target has:

- only the large-ingestion release-gate sources, the cold database-bootstrap source, and declared
  runtime data;
- the same compiled application dependency as the core integration shards;
- `//build:run_id_file` as declared data, `SERVICERADAR_ONLY_INTEGRATION=1`, and
  `SERVICERADAR_TEST_DB_SHARD=large_ingestion`;
- `test/db/integration_env.exs` loaded before the Elixir test configuration loader, matching the
  ordinary shard targets;
- a dedicated `large_ingestion` database suffix derived from that declared run-id file;
- the shared-fixture compatibility guard;
- `integration_test` and `large_ingestion_test` Bazel tags for discovery and policy;
- local, non-cached `TestRunner` execution under the guarded lifecycle.

The ordinary unit and integration source sets exclude the release-gate directory and the explicit
bootstrap source. This physical source boundary, not `exclude: :large_ingestion`, guarantees that
positive ExUnit includes cannot pull any heavy test back into one of the eight shard targets.

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

The bootstrap workload remains two production startup invocations against a fresh scratch
database. The first covers `:empty` by applying the committed baseline and pending migration
history; the second covers the normal `:migrated` restart branch and idempotence. It is moved, not
reduced. A quiet provisional serial cost of roughly 115 seconds already exceeds the complete
90-second PR goal, and the first pass exceeded its 300-second timeout during a true eight-shard
local treatment. A dedicated sequential PR phase would therefore impose an impossible latency
floor; the existing default-branch/nightly/release qualification cadence preserves coverage
without charging every pull request.

### Decision: Give the heavy test an independent BuildBuddy action
`buildbuddy.yaml` gains a separate action that uses the same runner pool, fixture setup, template
check, local database `TestRunner`, credential scoping, and outcome-bearing teardown as the PR
lifecycle. It triggers:

- on pushes to `staging`;
- nightly through a BuildBuddy `schedule` cron; and
- on release tags.

The action runs only the focused heavy provision and test targets, not all eight PR shards. The
stable action name and classic GitHub commit-status context are
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

### Decision: Rebalance with serial weight plus async makespan
The current partition gives heavy files priority because file-count round robin did not balance
runtime. Once heavy release qualification is extracted and some modules overlap, those hints are
stale.

After the async set is stable, all eight shards run in one separately labeled, non-cohort profiling
wave with `SERVICERADAR_TEST_SLOWEST` absent, the declared integration cap set to one, ExUnit tracing
enabled explicitly, and test timeouts disabled explicitly. This emits every case duration in one
consistent execution mode. ExUnit's built-in slowest report also changes runner semantics, so the
ordinary PR action, heavy gate, and controlled benchmark action must never enable it. Those
authoritative runs instead emit an effective-runner marker proving their configured `max_cases`,
trace mode, and timeout mode.

The complete profiling trace is aggregated by module. Rounded relative weights are checked in for
every selected module at or above the declared cutoff, while every selected module below it
receives one common default weight; that default is a scheduling unit, not an invented runtime claim. Profiling
durations never enter the before/after latency cohorts. A subsequent trace-free `max_cases: 2`
validation wave must meet the safety requirements before advancing to cap four; final placement is
then validated trace-free at `max_cases: 4`.

The sum-only LPT layout was useful while almost every module was serial, but it overstates work that
can overlap and can stack hard serial blockers behind the same shard. Final placement carries every
selected module job from the checked-in disposition inventory and computes:

```text
relative predicted shard load =
  retained_source_count * common_source_load_weight
  + sum(serial module weights)
  + list_schedule_makespan(async module weights, max_cases=4)
```

The common source-load weight is one relative unit for every retained file. Trace-derived module
weights are compared only with values from the same complete trace and never converted to wall-time
forecasts. List scheduling sorts async modules by descending measured weight and places each
indivisible module on the least-loaded one of four virtual slots. The outer partitioner then considers sources
in descending measured weight and assigns each source to the shard that minimizes the resulting
global predicted maximum, followed by candidate-shard load, source count, and shard name as stable
tie-breakers. Fixed-resource sources preseed `s7` and remain immovable. Tests prove deterministic,
disjoint placement, disposition completeness, and a synthetic case where sum-only LPT would hide a
serial critical path. A stale measured entry is harmless: if its source disappears it participates
in no assignment.

### Decision: Make one BEAM the primary measured topology challenger
The approximately 36-second BEAM/runfiles cost is paid by every shard in compute, but eight shard
starts overlap on the wall-clock critical path. Outer shards also distribute hard-serial work that
one BEAM would have to execute cumulatively. Existing trace-instrumented case weights and the
trace-free aggregate duration are intentionally not subtracted or used to forecast wall time: the
measurement modes are not commensurate. They are sufficient only for relative placement within a
single complete trace. Controlled lifecycle measurements decide whether avoiding BEAM startup
outweighs accumulating serial work.

The implementation provides non-gating, same-revision runner-layout diagnostics rather than
treating the model as proof. The one-BEAM arm is the primary analytical challenger: it
pays source loading and application startup once, uses one database, and lets ExUnit schedule the
audited transaction-safe modules within that VM. One-BEAM at cap eight, four-BEAM at cap seven, final eight-BEAM at
cap four, and five-BEAM hybrid variants use the same ordinary sources, trace-off mode, timeouts,
retry policy, current template, and fresh disposable databases. These are pre-registered deployable
bundles: BEAM count, per-BEAM cap, and aggregate Repo-pool capacity vary together, so results select
a runner layout and MUST NOT be attributed to BEAM count alone. Caps are frozen before the five
attempts and cannot be tuned after results are observed. Cap eight reserves four connections in
the one-BEAM Repo pool for application-owned work; cap 12 would have no checkout headroom and could
measure queue saturation instead of a viable layout. The hybrid
has two async lanes at cap seven plus three serial lanes at cap one, with an exhaustive,
disjoint union of ordinary core sources. Every multi-BEAM variant co-locates all fixed-external
sources in one designated serial lane. Four-BEAM sources are frozen from the same execution model
at cap seven. Hybrid async sources are balanced by cap-seven module makespan; hybrid serial sources
are balanced by source load plus serial-module LPT after fixed-external sources preseed one serial
lane. Static tests freeze deterministic membership and predicted relative loads. A separate diagnostic action swaps only those core labels,
while an identical checked-in SRQL/other non-core target list runs in every arm. A static contract
proves that list is exactly the production pull-request wildcard's ordinary target set minus the
production core labels and excluded heavy target. Every arm replaces only those core labels, and
its core source plus selected-test identity union must equal the production eight-shard core
workload. The action explicitly builds the selected manual labels with the measured configuration
before the clock. Five no-overlap
rounds rotate the one/four/eight/hybrid arm order by one position per round; each attempt records
lifecycle wall time, runner markers, connection peaks, failures, and residue. These rows never
enter the 20-run acceptance cohorts. The authoritative benchmark remains
the full pull-request integration wildcard and accepts no topology selector. The ordinary topology
remains eight shards unless a smaller or hybrid topology beats it by at least 10% and satisfies
every five-run screen safety and headroom gate. That result earns an explicit OpenSpec amendment;
the amended layout must then pass the full 20-run acceptance contract before adoption. No
diagnostic target is silently rewritten into production.

Template preparation and any migration run in a separate preflight before measurement. The
end-to-end measurement starts immediately before fixture configuration is materialized and its end
timestamp is captured immediately when teardown returns, before observer shutdown/wait overhead.
The in-clock template check is current-only; a newly pending result is retained as non-cohort and
cannot migrate inside the timing window. The preceding full-build step must have warmed the exact
Bazel configuration. The measured ordinary wave includes
every target selected by the pull-request integration filter (the eight core shards, the
designated shared-resource lane within them, SRQL fixture targets, and other existing integration
targets) and excludes only the source-separated heavy release-qualification target (the two
large-ingestion suites plus cold bootstrap). Over 20 consecutive runs, p95 is the nearest-rank
19th ordered value.

Acceptance requires:

- warm integration lifecycle p95 at or below 90 seconds;
- BuildBuddy relative p95 improvement of at least 50% against the controlled before cohort,
  including whether it reaches the 60% stretch target;
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
4. Add the startup-neutrality RED/GREEN regression, move suite-global audit configuration into
   `test_helper.exs`, and remove redundant startup from promoted modules.
5. Inventory every selected ExUnit module plus load-only source, prune unit-only sources after an
   exact selected-identity equivalence test, promote the nine fully audited broad-wave DataCase
   modules, and split or normalize prioritized mixed modules with explicit evidence.
6. Run the complete observed cap-two safety wave with retries disabled; repair any classification,
   ownership, queue, or cleanup defect before proceeding.
7. Profile once at cap one, replace sum-only LPT with concurrency-aware placement, advance all
   ordinary shards to cap four with Repo pool size pinned to 12, and run the safety wave only after
   the final placement is in effect.
8. Publish the diagnostic actions, run non-cohort 2-CPU versus 12-CPU diagnostics, and freeze the
   explicit safe CPU winner in production and benchmark actions.
9. Pass heavy/full repository verification, repair and freeze the before/after lineage without
   changing the verified final tree, publish exact SHAs, and run an exact-SHA BuildBuddy smoke.
10. Run rotated one-/four-/eight-BEAM plus hybrid runner-layout diagnostics on the frozen final SHA;
    retain eight shards unless an alternative clears the amendment threshold and later full gate.
11. Run 20 alternating exact-SHA before and final-cap-after BuildBuddy cohorts with retries
    disabled; require after p95 at most 90 seconds and at least 50% relative improvement, and
    report whether the 60% stretch target is reached.
12. Land the marker, complete qualifier, and workflow wiring atomically. After merge, verify the
   `staging` push status before tagging when practical; otherwise the tag-triggered action must
   satisfy the same exact-SHA poll within its 30-minute deadline.

Rollback first sets the cap back to two and quarantines the offending newly async module. If the
cap-two safety wave also fails, rollback sets the cap to one while preserving the corrected owner
lifecycle and explicit dispositions.
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
- The eight Repo pools already reserve more connections than the typical active query count. Both
  staged caps and the CPU experiment pin pool size to 12; acceptance records peak fixture
  connections and stops rollout if the existing 200-connection ceiling loses operational headroom.
- A larger CPU request can reduce scheduler starvation but also consumes more workflow-cluster
  capacity. The separate 2-versus-12 diagnostic and identical accepted-cohort request prevent an
  infrastructure change from being misattributed to the async implementation.
- Sustained eight-shard load can also exhaust one shard's checkout queue before the fixture reaches
  its global connection ceiling. A longer queue bound is not automatically a fix: it must be
  justified by a focused regression and a green full wave, while actual starvation, sandbox-owner
  loss, and a test crossing its timeout remain cohort-breaking failures.
- The separate heavy action adds default-branch compute. It removes that compute from every PR and
  runs only one BEAM/database, so total developer latency falls while coverage remains frequent.
- Release status enforcement introduces a dependency on the BuildBuddy action completing. The
  release workflow must report the pending/failed context clearly and time out rather than publish
  without evidence. The permanent introduction marker is part of the compatibility contract and
  must never be removed; checked-in behavior and workflow tests make deletion fail closed.

## Alternatives Considered

### Collapse every ordinary test into one BEAM
Selected as the primary measured challenger, not as an unmeasured production default.
Eight approximately 36-second startup/source-load phases overlap in wall time, so collapsing them
saves aggregate runner work rather than an automatic seven times 36 seconds of elapsed time. One
BEAM also accumulates every hard-serial module. Available measurements
do not support a valid one-BEAM wall-time forecast because the async audit uses trace-instrumented
case weights while the aggregate baseline is trace-free. The controlled topology diagnostic is the
decision evidence; a safety-clean winner may replace the eight-shard default through the stated
amendment and acceptance gate.

### Use one async BEAM plus serial-isolation targets
Retained as a measured challenger rather than the initial production topology. A hybrid can reduce
repeated compute, but it needs exhaustive async/serial source separation and enough serial lanes to
balance blockers; once those lanes exist it is still a multi-BEAM design. It may replace eight
ordinary shards only through the documented 10% improvement, safety gates, and proposal amendment.

### Increase from eight to sixteen Bazel shards
Rejected for the first iteration. Every extra shard repeats about 36 seconds of aggregate BEAM
startup/source-load work, increases Repo pools and fixture databases, and cannot divide a single
47-second test.

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
- None. The isolation classes, staged cap two-to-four rollout, full disposition audit,
  concurrency-aware placement, CPU/topology diagnostics, source-separated heavy gate, BuildBuddy
  schedule, and acceptance thresholds are the approved design. Diagnostic winners are selected by
  the explicit criteria above rather than an unresolved design choice.
