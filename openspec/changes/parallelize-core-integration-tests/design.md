## Context
Before this proposal, ServiceRadar core had two levels of database isolation:

1. Bazel partitions all core integration test files across eight `ex_unit_test` targets.
2. Each target receives a separately cloned PostgreSQL database (`s0` through `s7`), and each
   `ServiceRadar.DataCase` test starts a rollback-only Ecto SQL Sandbox owner.

The first level prevented independent BEAM VMs from deadlocking against one shared database. The
second level already had the semantics needed for concurrent transactional tests inside one BEAM,
but the baseline runner fixed `max_cases: 1` and nearly every DataCase module was declared
`async: false`.

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
- Keep the current template-clone path, TLS posture, credential scope, disposable-database guard,
  and cleanup guarantees while using exactly eight ordinary BEAM lanes.
- Run the user-directed production topology: one async BEAM at cap eight plus exactly seven
  deterministic serial lanes at cap one, then reserve the 20-run exact-SHA cohorts for final
  acceptance.

### Non-Goals
- Make every integration module async.
- Let a transaction sandbox pretend that DDL, NATS, application configuration, ETS, registries, or
  global supervisors are test-local.
- Add database lanes, Repo connections, or fixture capacity beyond the existing eight-BEAM /
  96-configured-slot envelope.
- Run ordinary serial work in the async BEAM or make topology/lane membership a post-measurement
  tuning knob.
- Change SRQL fixture tests, which already have separate database contracts and are not the
  measured critical path.
- Solve cold repository build times.

## Architecture

The ordinary pull-request path uses one shared async BEAM and deterministic serial BEAM lanes:

```text
BuildBuddy PR action
  -> prepare one current template
  -> verify live total server capacity funds the fixed 114-slot selected workload with 10% headroom
  -> clone sr_core_test_<run-id>_async and seven sr_core_test_<run-id>_serial_<n> databases
  -> run one async Bazel target plus exactly seven serial targets in parallel
       -> async: exactly one BEAM, max_cases 8, one rollback-only owner per active case
       -> serial: max_cases 1 per BEAM, one lane per disposable clone
       -> fixed shared-external-resource modules are preseeded in serial_0
       -> load-only sources are absent from every ordinary lane
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

### Decision: Freeze one async BEAM plus exactly seven serial lanes
ExUnit schedules only modules declared `async: true` concurrently. Production therefore has exactly
one async BEAM at frozen `max_cases: 8` and exactly seven serial BEAMs at frozen `max_cases: 1`.
The cap and lane are set by Bazel environment and parsed fail-closed by `test_helper.exs`.

Every lane pins a 12-connection Repo pool, so the fixed core topology is eight BEAMs and 96 pool
slots, matching the existing envelope. This topology was chosen and frozen at proposal time from
the fixture's audited 197 usable client slots:

```text
audited_safe_slots = floor(0.90 * 197) = 177
fixed_core_slots = 8 * 12 = 96
fixed_selected_workload_slots = 96 + 18 SRQL slots = 114
```

Before every run, the observer reads the server's live `max_connections` and reserved-connection
settings and fails before provisioning unless `114 <= floor(0.90 * usable_client_slots)`. That
preflight validates the fixed selected workload; it never rederives or shrinks the seven serial
lanes from current occupancy. The observer separately records run-scoped and fixture-wide occupancy
peaks. Except for its own reported administrator session, unrelated live fixture sessions remain in
the fixture-wide samples; they are not subtracted to manufacture an available-slot value. The fixed
lane count and final manifest-backed source membership are checked in and input-hashed before CPU
diagnostics or authoritative cohorts and are never tuned from timing results. Headroom is only for
processes supervised inside a test BEAM, never for a deployed application. A safety failure is
fixed by classification, owner routing, or workload—not by retries, a larger pool, or relaxed
timeouts.

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
`SERVICERADAR_TEST_DATABASE_POOL_SIZE=12`, run the same frozen async-cap-eight and serial-cap-one source topology, and
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
runs through the cap-two safety gate before the frozen async-cap-eight treatment.

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

### Decision: Keep projection-only inventory rollups off async owner transactions
The production `ocsf_devices` rollup trigger updates the singleton
`device_inventory_counts['total']` row for every device mutation. A normal request transaction is
short, but an ExUnit Sandbox transaction remains open for the complete test. Eight otherwise
independent device-writing tests therefore queue behind one row lock until their owners roll back;
when a table-locking operation enters the same graph, PostgreSQL can deadlock the writers.

The trigger already has a production bulk-write escape hatch:
`current_setting('platform.skip_inventory_rollup', true) = 'on'`. Immediately after an async
non-shared owner starts, test support sets that existing flag with `SET LOCAL`. The setting belongs
only to that rollback-only connection and transaction, is inherited by explicitly allowed child
processes using the same owner, and disappears when the owner ends. Serial/shared owners do not set
it. No trigger is disabled on the template or clone, and no production function gains a test-only
branch.

Async eligibility therefore also means that a test does not assert the cached inventory-rollup
projection. The existing `SyncIngestorVendorTypeTest` remains serial: it refreshes the projection,
performs a below-bulk-threshold device ingest, and proves the live row trigger updates total,
availability, type, and vendor counts. A database-backed sandbox regression proves the async
setting reaches allowed children, suppresses real trigger updates, does not leak to a fresh serial
owner, and leaves that serial owner's trigger enabled.

The shared-owner path legitimately multiplexes cooperating processes through one sandbox owner,
so bursts can queue at that ownership proxy even while the Repo pool still has capacity. The
default 50 ms queue bound is too short for that supported path: the focused regression observes a
waiting query being dropped after roughly 984 ms under sustained concurrent checkouts. The test
Repo therefore uses finite 1,000 ms `queue_target` and `queue_interval` defaults, preserves the
existing environment overrides and pool sizes, and must pass both that focused RED/GREEN regression
and a complete fixed-lane wave. This is a measured bound, not a general timeout ratchet; it must
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

That module-level flag is sufficient for state shared only by one lane database or one BEAM. It is
not sufficient for NATS streams, fixed subjects, or another fixture-global resource because serial
lanes are separate OS processes. Tests that use a fixed external namespace are pinned to `serial_0`
and remain `async: false`; no async lane or other serial lane may use that namespace. A test may
remain outside `serial_0` only when its external resource name is unique per test/run and cleanup is
scoped to that name.

The existing fixed-resource list is re-audited rather than inherited as truth. A row needs concrete
evidence of a mutable shared namespace, cross-BEAM negative assertion, or collision. A read-only
external smoke test such as the Proxmox API source is classified from its actual Repo, VM, and
external behavior and is not pinned merely because it was historically in the list.

`serial_0` is one of the seven frozen serial lanes, not an additional database or BEAM. It is
preseeded before deterministic serial LPT placement; no transaction-isolated source is added to it.
The source-class guard prevents every other lane from overlapping fixture-global resources through
the same namespace.

| Behavior | Required scope | Reason |
| --- | --- | --- |
| DDL, extension/graph changes, materialized-view refresh | `async: false` in any shard | Each outer shard has its own database, but catalog locks are not test-transaction local |
| `TRUNCATE` or committed cleanup | `async: false` in any shard | Cross-test locks and visibility conflict inside one database |
| `sandbox: :unboxed` | `async: false` in any shard | It disables the rollback boundary |
| fixed NATS stream/subject or another fixture-global name | `async: false` in `serial_0` only | The external state is shared across BEAMs |
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
async. A mixed-mode source must be split before source-level lane placement; the existing adhoc-scan
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

This is guarded by behavior rather than tag-text heuristics alone. Six database-free
`IntegrationSelectionManifestRunner` chunks load the corpus without starting the application or
running test bodies: two cover the pruned selected-source candidate and four cover the load-only
complement. The runner evaluates the real `ExUnit.Filters` include/exclude configuration and emits
delimiter-safe `(source, module, test-name)` identities. The selected-chunk union must exactly equal
the union of all six chunks before the production shard sources change, and every load-only chunk
must emit no selected identity. Files containing selected and unselected modules are allowed only
when all selected modules have one async mode. Files containing selected modules with mixed async
modes are split. The adhoc-scan NATS source is split so its selected global case and unrelated async
cases are source-addressable. The anomaly-profile seeder's one selected database module remains
beside an unselected schema-only module; because the selected module changes VM-global Logger
configuration, the entire retained integration source is serial.

Placement models exact selected test-identity counts aggregated by source because ExUnit schedules
the selected module jobs rather than every loaded file. It adds a separate common source-load
weight for every retained serial source rather than fabricating serial case time for `load_only`
files. The checked-in ordinary source list equals the distinct sources having async/serial module
rows; the async-safe source list equals sources whose selected module rows are all async. The real
database-free ExUnit filter pass exact-checks the count projection against the identity union.

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
- an explicitly pinned parent `ServiceRadar.Repo` pool size of 12;
- a fixed pool size of 2 for the normal child Repo started by cold bootstrap while the parent Repo
  remains alive;
- one direct Postgrex administrator connection opened concurrently by `StartupMigrations`, counted
  as heavy workload capacity rather than as observer overhead;
- `integration_test` and `large_ingestion_test` Bazel tags for discovery and policy;
- local, non-cached `TestRunner` execution under the guarded lifecycle.

The ordinary unit and integration source sets exclude the release-gate directory and the explicit
bootstrap source. This physical source boundary, not `exclude: :large_ingestion`, guarantees that
positive ExUnit includes cannot pull any heavy test back into an ordinary lane target.

The dedicated target retains `integration_test` so the ordinary unit wildcard continues excluding
it, and adds `large_ingestion_test`. The pull-request integration wildcard changes to
matching build/test filters of `integration_test,-large_ingestion_test,-acceptance_test` and adds
`--build_tests_only`. This second boundary prevents Bazel from building or running the dedicated
target itself, as well as unrelated non-test wildcard targets, when the workflow asks for all
integration-tagged targets. Source separation protects ExUnit selection inside the shards; the
negative Bazel target tag and build-only-test restriction protect wildcard target selection.

`build/integration_shards.bzl` exports the dedicated suffix separately from the async and serial lane suffixes.
`provision_db` clones only the eight frozen ordinary lane databases; a focused
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
reduced. `max_cases: 1` serializes ExUnit modules but does not eliminate the Repo overlap: the
parent pool of 12 remains alive while cold bootstrap starts its normal child pool of 2, and
`StartupMigrations` concurrently opens one direct Postgrex administrator connection. The heavy
lifecycle therefore has a 15-slot configured workload envelope. A quiet provisional serial cost
of roughly 115 seconds already exceeds the complete
90-second PR goal, and the first pass exceeded its 300-second timeout during a true eight-shard
local treatment. A dedicated sequential PR phase would therefore impose an impossible latency
floor; the existing default-branch/nightly/release qualification cadence preserves coverage
without charging every pull request.

### Decision: Give the heavy test an independent BuildBuddy action
`buildbuddy.yaml` gains a separate action that uses the same runner pool, fixture setup, template
check, local database `TestRunner`, credential scoping, and outcome-bearing teardown as the PR
lifecycle. It triggers:

- on pushes to `staging`; and
- nightly through a BuildBuddy `schedule` cron.

It does **not** trigger on `v*` tags. Tagging the chore commit while the
staging merge uses a different SHA queued a second 50GB job that never started
(`queued=true`, invocation not found) while publication polled the tag SHA.

The action runs only the focused heavy provision and test targets, not all eight PR shards. The
stable action name and classic GitHub commit-status context are
`LargeIngestionGate`. BuildBuddy's linked GitHub App, not a credential passed into the Bazel action,
posts that status for the exact workflow commit with a BuildBuddy target URL.

Before `provision_db_large_ingestion`, the action starts the Bazel-owned observer with
`required_pool_slots=15` and waits for its ready handshake. That reservation is the parent Repo's
12 configured slots, the concurrently possible cold-bootstrap child Repo's 2 slots, and the one
direct Postgrex administrator connection opened by `StartupMigrations`. It is independent of the
ordinary workflow's 114-slot preflight; the observer's own administrator connection is excluded
from the workload reservation and reported separately. If the live total server capacity cannot
fund all 15 workload slots while retaining 10% headroom, the heavy action fails before provisioning.

The release workflow already resolves the immutable tag commit. After Bazelisk and the authenticated
remote configuration are available, but before Cosign, ORAS, artifact builds, or publication, it
runs a Bazel-owned Python qualifier. The executable receives the exact release SHA, repository,
fetched `origin/staging` ref, and GitHub token environment-variable name. It invokes `gh api`
without a shell, polls GitHub's commit status API for context `LargeIngestionGate` on that SHA
and on first-parent descendants of it on `origin/staging` whose git tree SHA matches (the
merge commit of an ancestry-preserving release merge). It accepts only `success` whose parsed
URL has HTTPS scheme, host exactly `carverauto.buildbuddy.io`, and a nonempty `/invocation/<id>`
path. Classic statuses are append-only, so each poll filters the exact context, orders matching
records by creation time and status id, and evaluates only the newest record per SHA. An older
success cannot mask a newer pending, error, or failure on the same SHA. A pending or failed
status on the tag SHA does not fail qualification while a same-tree staging descendant is still
missing or pending. The workflow waits at most 90 minutes and fails closed on timeout, API
error, malformed data, or every candidate being terminal-failed.

One current successful status for the tag SHA or a same-tree staging descendant is sufficient;
the policy proves the tested source tree, not which event started the run. Tag origin/staging
only after that status is already success so publication does not sit on a phantom queued job. The implementation commit adds a permanent
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

### Decision: Freeze source membership before CPU diagnostics and authoritative timing
The final checked-in disposition is the only source of ordinary-lane membership. Every source whose
selected modules are all async goes to the single async BEAM; every selected serial source goes to a
serial lane; and every `load_only` source is absent. A mixed selected-mode source must be split
before it can enter this topology.

`serial_0` receives every `fixed_external` source first. The remaining serial sources are placed
with deterministic LPT using the pre-measurement weight
`1 + selected_serial_test_identity_count`. Sources are ranked by descending weight then source
path; each is placed in the lane with the least current load, then fewest sources, then lane name.
The identity count is emitted by the existing database-free selection runner using ExUnit's real
include/exclude filters, checked in as a Starlark projection, and verified against the exact
selected identity union. It is a reproducible workload-size proxy, not a wall-time forecast. The
checked-in eight-lane topology, source map, counts, and exact selected identity union are built and
validated before CPU diagnostics or authoritative cohorts start. A runtime timing result cannot
change them.

The first trace-free smoke exposed why the earlier module-count proxy could not be accepted: all
159 serial sources contained one selected module, so every weight was two and the purported LPT
assignment degenerated to alphabetical source-count round-robin. Its 24.5--45.0 second serial-lane
spread failed the already-defined 1.5 balance gate. That smoke invalidates the candidate map; it is
not an authoritative cohort and none of its per-lane timings is used as a source weight. Replacing
the uniform proxy with selection-manifest identity counts is a proposal amendment made before the
new map is frozen.

The async lane has no outer placement decision: it receives every all-async selected source once and
ExUnit list-schedules its selected module jobs at cap eight. The serial lanes use only the frozen
database-free LPT source weight above. Later traces can describe the resulting workload but cannot
retune the production lane count or membership for the measured revision.

### Decision: Production topology is not a challenger matrix
The ordinary topology is fixed by the ruling: one async BEAM at cap eight and exactly seven serial
BEAM lanes at cap one. It is not compared with one/four/eight/hybrid alternatives and no result can
silently change it. The async cap leaves four connections in that same test BEAM's 12-connection
pool for test-owned processes such as sharded alert-engine workers. They are not held for any
deployed ServiceRadar application, and no demo or production workload participates in this
lifecycle. Cap 12 would remove the test-BEAM checkout headroom and is forbidden.

Every ordinary lane uses the same source revision, trace-off mode, finite timeouts, retry policy,
current template, per-BEAM pool size, and disposable-fixture contract. The authoritative benchmark
measures this fixed source union; it has no topology selector. Any future topology change requires a
new approved OpenSpec change and a new exact-SHA acceptance cohort.

Template preparation and any migration run in a separate preflight before measurement. The
end-to-end measurement starts immediately before fixture configuration is materialized and its end
timestamp is captured immediately when teardown returns, before observer shutdown/wait overhead.
The in-clock template check is current-only; a newly pending result is retained as non-cohort and
cannot migrate inside the timing window. The preceding integration-only prebuild must have warmed
the exact Bazel configuration, measured target dependency closures, and the four manual lifecycle
targets that execute inside the clock. It must not build unrelated packages, release archives, OCI
images, or push targets. The measured `bazel test //...` command pairs `--build_tests_only` with
identical build/test tag filters; `--test_tag_filters` alone is insufficient because Bazel can still
build excluded tests and unrelated non-test wildcard targets. The measured ordinary wave includes
every target selected by the pull-request integration filter (the async target, all selected serial
targets, SRQL fixture targets, and other existing integration targets) and excludes only the
source-separated heavy release-qualification target (the two
large-ingestion suites plus cold bootstrap). Over 20 consecutive runs, p95 is the nearest-rank
19th ordered value.

Acceptance requires:

- warm integration lifecycle p95 at or below 90 seconds;
- BuildBuddy relative p95 improvement of at least 50% against the controlled before cohort,
  including whether it reaches the 60% stretch target;
- 20 consecutive retry-free before attempts and 20 consecutive retry-free after attempts under an
  identical exact-SHA harness;
- no serial lane more than 1.5 times the runtime of the fastest non-empty serial lane in any
  accepted after run;
- sampled run-scoped connections at most 114 (the core topology's 96 slots plus three existing
  SRQL integration targets at six connections each) and fixture-wide connections, including
  unrelated live fixture sessions but excluding the observer's reported administrator session, at
  most `floor(live usable client slots * 0.90)` in every accepted after run;
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

Every CI, CPU-diagnostic, and cohort database in this proposal is a disposable
`sr_core_test_<run-id>_<lane>` clone on the development-only `srql-fixtures` CNPG fixture. Neither
`demo` nor any production database is a permitted endpoint. Repo-pool headroom refers only to
components started inside the test BEAM, such as the alert engine's sharded GenServers; it is not
capacity reserved for a deployed application. Focused direct Mix runs fail before Repo startup
unless they identify the same fixture with verified TLS and use a separately created disposable
scratch database.

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
- A heavy observer preflight that cannot fund the parent pool of 12, the concurrent cold-bootstrap
  child pool of 2, and `StartupMigrations`' one direct Postgrex administrator connection fails
  before readiness and provisioning; serial ExUnit scheduling MUST NOT reduce that 15-slot
  reservation.
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
   `serial_0`, and audit the first transaction-only modules.
4. Add the startup-neutrality RED/GREEN regression, move suite-global audit configuration into
   `test_helper.exs`, and remove redundant startup from promoted modules.
5. Inventory every selected ExUnit module plus load-only source, prune unit-only sources after an
   exact selected-identity equivalence test, promote the nine fully audited broad-wave DataCase
   modules, and split or normalize prioritized mixed modules with explicit evidence.
6. Run the complete observed cap-two safety wave with retries disabled; repair any classification,
   ownership, queue, or cleanup defect before proceeding.
7. Freeze the complete manifest-backed source map before CPU diagnostics or authoritative cohorts:
   one async lane at cap eight and exactly seven serial lanes at cap one, with Repo pool size pinned
   to 12. Run the safety wave only after that placement is in effect.
8. Publish the diagnostic actions, run non-cohort 2-CPU versus 12-CPU diagnostics, and freeze the
   explicit safe CPU winner in production and benchmark actions.
9. Pass heavy/full repository verification, repair and freeze the before/after lineage without
   changing the verified final tree, publish exact SHAs, and run an exact-SHA BuildBuddy smoke.
10. Run 20 alternating exact-SHA before and frozen-lane-after BuildBuddy cohorts with retries
    disabled; require after p95 at most 90 seconds and at least 50% relative improvement, and
    report whether the 60% stretch target is reached.
11. Land the marker, complete qualifier, and workflow wiring atomically. After merge, verify the
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
  staged caps and the CPU experiment pin pool size to 12; the observer validates that live total
  server capacity funds the fixed 114-slot workload with 10% headroom, while acceptance records
  fixture-wide peak occupancy including unrelated fixture sessions and stops rollout if operational
  headroom is lost.
- A larger CPU request can reduce scheduler starvation but also consumes more workflow-cluster
  capacity. The separate 2-versus-12 diagnostic and identical accepted-cohort request prevent an
  infrastructure change from being misattributed to the async implementation.
- Sustained eight-shard load can also exhaust one shard's checkout queue before the fixture reaches
  its global connection ceiling. A longer queue bound is not automatically a fix: it must be
  justified by a focused regression and a green full wave, while actual starvation, sandbox-owner
  loss, and a test crossing its timeout remain cohort-breaking failures.
- The separate heavy action adds default-branch compute. It removes that compute from every PR and
  runs only one ExUnit BEAM/database, so total developer latency falls while coverage remains
  frequent. During cold bootstrap that BEAM's 12-slot parent Repo overlaps a 2-slot normal child
  Repo and `StartupMigrations`' direct Postgrex administrator connection, so capacity planning and
  observer preflight must reserve 15 rather than infer 12 from the one-BEAM topology.
- Release status enforcement introduces a dependency on the BuildBuddy action completing. The
  release workflow must report the pending/failed context clearly and time out rather than publish
  without evidence. The permanent introduction marker is part of the compatibility contract and
  must never be removed; checked-in behavior and workflow tests make deletion fail closed.

## Alternatives Considered

### Collapse every ordinary test into one BEAM
Rejected. One BEAM would accumulate every hard-serial module and would remove the separate serial
database/process boundaries required by the audit.

### Split async work across multiple BEAMs
Rejected. The ruling requires exactly one shared async BEAM. Serial parallelism is provided only by
the seven frozen serial lanes, whose manifest-backed membership is frozen before CPU diagnostics
and authoritative cohorts.

### Increase beyond eight ordinary BEAM lanes
Rejected. Every extra lane repeats BEAM startup/source-load work and would exceed the fixed
96-configured-slot pool envelope.

### Raise `max_cases` for every module
Rejected. `async: false` modules would still serialize, while changing all modules to async would
race DDL, NATS, application configuration, and global supervisors.

### Give every test file its own database
Rejected. Template cloning is cheap, but BEAM startup and runfiles staging are not; source placement
is intentionally fixed at one async lane plus exactly seven serial lanes.

### Use unboxed transactions like ordinary tests
Rejected. Unboxed mode exists specifically for behavior that cannot run inside the sandbox
transaction. It commits and therefore cannot provide Diesel-like implicit rollback.

### Rely on the `:large_ingestion` exclude tag
Rejected. Positive ExUnit includes take precedence over excludes. Source separation is the chosen
structural guarantee that ordinary shard targets cannot compile or select the heavy test, paired
with a negative Bazel tag filter so the wildcard cannot select its dedicated target.

## Open Questions
- None. The isolation classes, full disposition audit, fixed async/serial lane topology,
  source-separated heavy gate, BuildBuddy schedule, and acceptance thresholds are approved.
