# Parallel Core Integration Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the warm ordinary pull-request integration lifecycle to a retry-free p95 of 90 seconds or less while preserving database, process, external-resource, and release-gate isolation.

**Architecture:** Run exactly one shared async BEAM at ExUnit cap eight and seven serial BEAMs at
cap one, each against its own template-cloned disposable PostgreSQL database on `srql-fixtures`.
Pin every Repo pool to 12, place serial sources with database-free selected-test-identity LPT, and
confine fixed external resources to `serial_0`. Source-separate heavy qualification into its own
BuildBuddy gate. Use one instrumentation-only baseline commit and the same non-merging benchmark
action for controlled 20-run before/after cohorts.

**Tech Stack:** Elixir 1.19, ExUnit, Ecto SQL Sandbox, Bazel/Starlark, Rust/tokio-postgres, BuildBuddy Workflows, GitHub Actions, Python `unittest` static contract tests.

**Spec:** `openspec/changes/parallelize-core-integration-tests/` (especially `design.md`, `benchmark.md`, and `specs/integration-test-execution/spec.md`)

> **Historical audit state (2026-08-23):** The initial candidate list below contained six async
> promotions. Runtime-path review proved that the four composite-check modules can reach the global
> `Oban.cancel_all_jobs/1` path, so they remain `async: false`. Only advisory feed loader and secret
> broker audit were promoted in the narrow pass. The separate broad-async plan then superseded that
> narrow pass. The active OpenSpec and Task 8 below now supersede both plans' older `s0..s7`, cap-two
> or cap-four, measured-weight, and `s7` fixed-resource instructions. Tasks 1--7 retain historical
> implementation evidence; their obsolete topology language is not an executable current ruling.

## Global Constraints

- Use the isolated worktree `/Users/mfreeman/src/serviceradar-wt-parallel-integration-tests` on branch `proposal/parallelize-integration-tests`.
- Keep exactly eight ordinary database lanes named `async` and `serial_0` through `serial_6`; do
  not increase the 12-connection Repo pool per lane.
- Set the async ExUnit cap to exactly `8` and every serial cap to exactly `1`; missing, malformed,
  zero, negative, or lane-incompatible integration values fail before tests execute.
- Async promotion is opt-in. `:unboxed`, DDL, `TRUNCATE`, refresh, app-global state, global process, true multi-connection, fixed NATS, and live external tests remain serial.
- Fixed shared-external-resource sources are `async: false` and exist only in `serial_0`.
- The 50,000-device router gate and 500-device/three-round identifier-cardinality gate remain full-strength and move outside ordinary test source sets.
- All database-facing TestRunner actions stay local and non-cached; credentials remain scoped to the guarded integration lifecycle.
- Preserve `sweep -> prepare -> conditional migrate -> provision -> suite -> teardown`, live CA, `verify-full`, the declared run-id file, and outcome-bearing teardown.
- Add no shell script and extend no shell script. Workflow sequencing remains inline YAML; new executable behavior is a Bazel target.
- Do not read generated Bazel output. Use target results, BuildBuddy logs, and declared test inputs.
- Follow strict red-green TDD for each behavioral task and use `apply_patch` for file edits.
- Before a completion claim, run `make lint`, `make test`, `git diff --check`, and strict OpenSpec validation with fresh output.

## File map

- `rust/integration-db/src/connection_observer.rs`: pure peak aggregation plus live `pg_stat_activity` sampling.
- `rust/integration-db/src/bin/observe_connections.rs`: bounded Bazel-owned observer used by measured workflows.
- `rust/integration-db/src/lib.rs` and `rust/integration-db/BUILD.bazel`: observer exports/target and focused heavy provisioner.
- `build/integration_shards.bzl`: the one-async-plus-seven-serial lane, max-cases, heavy-suffix,
  async-audit, manifest-backed placement, and fixed-resource source contract.
- `build/integration_shards_test.bzl` and `build/BUILD.bazel`: hermetic Starlark topology tests.
- `elixir/serviceradar_core/test/support/{test_support,data_case}.ex`: Sandbox ownership, allowance, cap parser, and guidance.
- `elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs`: ownership/guard/allowance/parser regressions.
- `elixir/serviceradar_core/test/test_helper.exs`: fail-closed integration concurrency configuration.
- `elixir/serviceradar_core/BUILD.bazel`: ordinary source exclusion, shared runtime data, cap env, and dedicated release target.
- `elixir/serviceradar_core/test/release_gates/large_ingestion/*.exs`: the two physically separated release suites.
- Two promoted DataCase files, four explicitly serial composite-check files, and
  `test/ASYNC_INTEGRATION_AUDIT.md`: the first conservative async wave and evidence.
- `buildbuddy.yaml`: unchanged benchmark action across revisions, ordinary filter/measurement, and `LargeIngestionGate`.
- `build/ci/large_ingestion_gate_contract.v1`: permanent introduction boundary for historical
  release compatibility.
- `build/ci/large_ingestion_gate.py`, `wait_for_large_ingestion_gate.py`, and tests: Bazel-owned,
  fail-closed exact-SHA release qualification.
- `.github/workflows/release.yml`: invokes the exact-SHA qualifier after Bazel setup and before
  release tooling or publication.
- `ci_heavy_gate_contract_test.py` and root `BUILD.bazel`: hermetic drift checks across all contract halves.
- `openspec/changes/parallelize-core-integration-tests/{benchmark,tasks}.md`: raw evidence and completion ledger.

## Exact execution recipes referenced below

Resolve the generated shard that owns the Sandbox regression source instead of guessing its shard:

```bash
SANDBOX_TARGETS="$(bazel query --output=label 'attr(srcs, ".*test_support_sandbox_test.exs", tests(//elixir/serviceradar_core:integration_tests))')"
test "$(printf '%s\n' "$SANDBOX_TARGETS" | sed '/^$/d' | wc -l | tr -d ' ')" = "1"
SANDBOX_TARGET="$SANDBOX_TARGETS"
```

Every instruction to run a guarded database lifecycle uses one of two explicit profiles. Workflow
actions set `BAZEL_PROFILE=ci`; a workstation sets `BAZEL_PROFILE=remote` because `ci` references the
executor-only `/bazel-cache`. The `.bazelrc.remote` worktree symlink must exist before either local
build or test. All local task verification below means the `remote` form.

Before a measured lifecycle, run template preflight in a subshell with a separate run id and fixture
environment file: materialize fixture configuration, run `prepare_template`, conditionally run
`migrate_template`, then run `prepare_template` again and require it to report current. This
preflight is outside the benchmark clock and its environment does not leak from the subshell. A
measured phase runs `prepare_template` again but MUST NOT migrate; a newly pending result is retained
as a non-cohort warm-up/failure row, cleanup runs, and the invocation is repeated only after another
out-of-clock preflight.

```bash
(
  set -euo pipefail
  case "${BAZEL_PROFILE:?set BAZEL_PROFILE to ci or remote}" in
    ci|remote) ;;
    *) echo "invalid BAZEL_PROFILE" >&2; exit 1 ;;
  esac
  export SERVICERADAR_ENV=ci
  PREFLIGHT_RUN_ID="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
  export RUN_ID="$PREFLIGHT_RUN_ID"
  SERVICERADAR_FIXTURE_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/serviceradar-preflight-env.XXXXXX")"
  export SERVICERADAR_FIXTURE_ENV_FILE
  trap 'rm -f "$SERVICERADAR_FIXTURE_ENV_FILE"' EXIT
  bazel run -c opt --config="$BAZEL_PROFILE" --//build:enable_integration_tests \
    --//build:run_id="$RUN_ID" //:buildbuddy_setup_fixture_env
  set -a
  . "$SERVICERADAR_FIXTURE_ENV_FILE"
  set +a
  PREFLIGHT_FLAGS="-c opt --config=$BAZEL_PROFILE --strategy=TestRunner=local
    --//build:enable_integration_tests --//build:run_id=$RUN_ID
    --test_env=SERVICERADAR_ENV=ci --flaky_test_attempts=1
    --nocache_test_results --noremote_upload_local_results
    --test_env=SERVICERADAR_SECRET_DATABASE_PASSWORD
    --test_env=SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD
    --test_env=SERVICERADAR_SECRET_DGRAPH_ADMIN_PASSWORD
    $SERVICERADAR_TEST_ENV_FLAGS"
  template="$(bazel run -c opt --config="$BAZEL_PROFILE" --//build:enable_integration_tests \
    --//build:run_id="$RUN_ID" //rust/integration-db:prepare_template)"
  case "$template" in
    *"migration(s) pending"*) bazel test $PREFLIGHT_FLAGS //elixir/serviceradar_core:migrate_template ;;
  esac
  template="$(bazel run -c opt --config="$BAZEL_PROFILE" --//build:enable_integration_tests \
    --//build:run_id="$RUN_ID" //rust/integration-db:prepare_template)"
  case "$template" in
    *"migration(s) pending"*) echo "template still pending after preflight" >&2; exit 1 ;;
  esac
)
```

The measured inline action begins with these exact setup flags and task-specific targets:

```bash
set -euo pipefail
umask 077
case "${BAZEL_PROFILE:?set BAZEL_PROFILE to ci or remote}" in
  ci|remote) ;;
  *) echo "invalid BAZEL_PROFILE" >&2; exit 1 ;;
esac
now_ns() {
  if [ "$BAZEL_PROFILE" = "ci" ]; then
    date +%s%N
  else
    python3 -c 'import time; print(time.time_ns())'
  fi
}
export SERVICERADAR_ENV=ci
RUN_ID="$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
export RUN_ID
SERVICERADAR_FIXTURE_ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/serviceradar-fixture-env.XXXXXX")"
export SERVICERADAR_FIXTURE_ENV_FILE
OBSERVER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/serviceradar-observer.XXXXXX")"
READY_FILE="$OBSERVER_DIR/ready"
SUITE_COMPLETE_FILE="$OBSERVER_DIR/suite-complete"
QUIESCENT_FILE="$OBSERVER_DIR/quiescent"
STOP_FILE="$OBSERVER_DIR/stop"
OBSERVER_LOG="$OBSERVER_DIR/observer.log"
test ! -e "$READY_FILE" && test ! -e "$SUITE_COMPLETE_FILE" && \
  test ! -e "$QUIESCENT_FILE" && test ! -e "$STOP_FILE"
START_NS="$(now_ns)"
bazel run -c opt --config="$BAZEL_PROFILE" --//build:enable_integration_tests --//build:run_id="$RUN_ID" //:buildbuddy_setup_fixture_env
set -a
. "$SERVICERADAR_FIXTURE_ENV_FILE"
set +a
FLAGS="-c opt --config=$BAZEL_PROFILE --strategy=TestRunner=local --//build:enable_integration_tests
  --//build:run_id=$RUN_ID --test_env=SERVICERADAR_ENV=ci --flaky_test_attempts=1
  --test_output=all
  --nocache_test_results --noremote_upload_local_results
  --test_env=SERVICERADAR_SECRET_DATABASE_PASSWORD
  --test_env=SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD
  --test_env=SERVICERADAR_SECRET_DGRAPH_ADMIN_PASSWORD
  $SERVICERADAR_TEST_ENV_FLAGS"
```

The lifecycle starts the observer with all four child marker paths and `--max-seconds 1800`, waits
no more than 30 seconds for `READY_FILE`, and runs `sweep_stale_dbs`, a current-only
`prepare_template` check, the selected provision target, and the selected suite. Cleanup always
writes `SUITE_COMPLETE_FILE`, waits no more than 30 seconds for two zero run-scoped samples, and
attempts `teardown_db`. It captures `END_NS` immediately when that teardown attempt returns, before
writing `STOP_FILE` or waiting for the observer; lifecycle seconds are derived only from
`START_NS..END_NS`. It then stops/waits for the observer, removes its private directory and fixture
file, and returns suite status before observer status before teardown status. The target matrix is
fixed:

| Use | Provision target | Suite selection |
| --- | --- | --- |
| Ordinary/benchmark | `//rust/integration-db:provision_db` | `--build_tests_only --build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test --test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test //...` |
| Focused Sandbox | `//rust/integration-db:provision_db` | the single resolved `$SANDBOX_TARGET` |
| Heavy gate | `//rust/integration-db:provision_db_large_ingestion` | `//elixir/serviceradar_core:large_ingestion_release_gate` |

Do not turn this sequence into a repository script. Tasks 1 and 6 encode it in the two workflow
action blocks and the static contract test checks every ordering and outcome boundary.

---

### Task 1: Add the observer and freeze the instrumentation-only baseline

**Files:**
- Create: `rust/integration-db/src/connection_observer.rs`
- Create: `rust/integration-db/src/bin/observe_connections.rs`
- Modify: `rust/integration-db/src/lib.rs`
- Modify: `rust/integration-db/BUILD.bazel`
- Modify: `buildbuddy.yaml`
- Create: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`

**Interfaces:**
- Consumes: `serviceradar_integration_db::{connect_admin, database_name}` and `//build:run_id_file`.
- Produces: `connection_observer::Peaks::record`, `connection_observer::sample`, Bazel targets
  `//rust/integration-db:observe_connections` and `//:integration_benchmark_harness_hash`, plus
  explicit-only BuildBuddy action `IntegrationBenchmark`.

- [ ] **Step 1: Write failing pure Rust tests**

Create the module with tests first and add `pub mod connection_observer;` to `src/lib.rs` in this
same red step so the library target must compile them:

```rust
#[test]
fn records_independent_run_and_fixture_peaks() {
    let mut peaks = Peaks::default();
    peaks.record(7, 31);
    peaks.record(12, 29);
    peaks.record(9, 44);
    assert_eq!(peaks, Peaks { samples: 3, run_scoped: 12, fixture_wide: 44 });
}

#[test]
fn summary_is_one_machine_readable_log_line() {
    let peaks = Peaks { samples: 4, run_scoped: 16, fixture_wide: 51 };
    assert_eq!(
        peaks.summary_json(
            "sr_core_test_deadbeef",
            SampleWindow { start_ms: 1_777_000_000_000, end_ms: 1_777_000_003_000 },
            Capacity { max: 200, superuser_reserved: 3, reserved: 0 },
        ),
        r#"{"sample_interval_ms":500,"samples":4,"sample_window_start_ms":1777000000000,"sample_window_end_ms":1777000003000,"observer_sessions_excluded":1,"run_prefix":"sr_core_test_deadbeef","run_scoped_peak":16,"fixture_wide_peak":51,"max_connections":200,"superuser_reserved_connections":3,"reserved_connections":0,"usable_client_slots":197}"#
    );
}

#[test]
fn run_prefix_query_treats_underscores_literally() {
    assert!(RUN_SCOPED_COUNT_SQL.contains("left(datname, char_length($1)) = $1"));
    assert!(!RUN_SCOPED_COUNT_SQL.contains("LIKE"));
}

#[test]
fn parser_rejects_missing_duplicate_and_unknown_flags() {
    assert!(ObserverArgs::parse(["observe_connections"]).is_err());
    assert!(ObserverArgs::parse(["observe_connections", "--stop-file", "a", "--stop-file", "b"]).is_err());
    assert!(ObserverArgs::parse(["observe_connections", "--wat", "x"]).is_err());
}

#[test]
fn quiescence_requires_two_post_suite_zero_samples() {
    let mut state = Quiescence::default();
    assert!(!state.record(false, 0));
    assert!(!state.record(true, 0));
    assert!(!state.record(true, 1));
    assert!(!state.record(true, 0));
    assert!(state.record(true, 0));
}

#[test]
fn completion_fails_closed_on_deadline_or_early_stop() {
    assert!(completion_status(false, false, true).is_err());
    assert!(completion_status(false, true, false).is_err());
    assert_eq!(completion_status(true, true, false), Ok(()));
}
```

- [ ] **Step 2: Run red**

Run `bazel test -c opt --config=remote //rust/integration-db:serviceradar_integration_db_test`.
Expected: FAIL because `Peaks`, `Capacity`, `SampleWindow`, `ObserverArgs`, `Quiescence`, query and
completion helpers, and their methods do not exist. A green result means the new module was not
exported and the red step is invalid.

- [ ] **Step 3: Implement aggregation, capacity, and sampling**

Use these public shapes:

```rust
pub const SAMPLE_INTERVAL_MS: u64 = 500;
const OBSERVER_SESSIONS_EXCLUDED: u64 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ConnectionCounts { pub run_scoped: u64, pub fixture_wide: u64 }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Capacity { pub max: u64, pub superuser_reserved: u64, pub reserved: u64 }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct SampleWindow { pub start_ms: u64, pub end_ms: u64 }

impl Capacity {
    pub fn usable_client_slots(self) -> u64 {
        self.max.saturating_sub(self.superuser_reserved).saturating_sub(self.reserved)
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Peaks { pub samples: u64, pub run_scoped: u64, pub fixture_wide: u64 }

impl Peaks {
    pub fn record(&mut self, run_scoped: u64, fixture_wide: u64) {
        self.samples += 1;
        self.run_scoped = self.run_scoped.max(run_scoped);
        self.fixture_wide = self.fixture_wide.max(fixture_wide);
    }
}
```

`sample(&Client, run_prefix)` queries `pg_stat_activity`, excludes `pg_backend_pid()` from both
counts, counts databases with the literal predicate
`left(datname, char_length($1)) = $1` (never an unescaped `LIKE`, because run ids contain `_`), and
counts fixture-wide `client backend` rows. `capacity(&Client)` queries live `max_connections`,
`superuser_reserved_connections`, and nullable
`reserved_connections`. Convert signed PostgreSQL values with checked conversions and never log a
DSN or credential. The summary includes epoch-millisecond sample-window boundaries and
`observer_sessions_excluded: 1`. Export the module from `lib.rs`.

- [ ] **Step 4: Implement a bounded observer binary**

Parse exactly `--ready-file`, `--suite-complete-file`, `--quiescent-file`, `--stop-file`, and
`--max-seconds` through the tested `ObserverArgs::parse`. Reject missing, duplicate, or unknown flags. Connect with `connect_admin(None)`,
sample once, write the ready marker, and sample every 500 ms. After the suite-complete marker
appears, write the quiescent marker only after two consecutive run-scoped zero samples. Continue
sampling until the stop marker appears after teardown, then print
`SERVICERADAR_CONNECTION_OBSERVER {json}` and exit zero. If the deadline arrives or quiescence is
not observed, print the summary and exit non-zero. The observer's admin connection targets
`postgres` and is excluded by PID.

- [ ] **Step 5: Register and verify the observer**

Register a manual `rust_binary` with `FIXTURE_DATA`, the shared-fixture guard, all normal crate
deps, `:serviceradar_integration_db`, and `//rust/srql:srql_lib`. Run:

```bash
cargo fmt --check --all
bazel test -c opt --config=remote //rust/integration-db:serviceradar_integration_db_test
bazel build -c opt --config=remote --//build:enable_integration_tests //rust/integration-db:observe_connections
```

Expected: PASS.

- [ ] **Step 6: Write a red static contract for `IntegrationBenchmark`**

Create a root Python `unittest`, registered as `//:ci_heavy_gate_contract_test`, with every file it
currently inspects in `data`; later tasks extend `data` when their new sources exist. Extract action
blocks by exact `- name:` boundaries. Assert
`IntegrationBenchmark` uses the existing runner image/pool, asserts requested SHA equals `HEAD`, sets
`--flaky_test_attempts=1`, `--test_output=all`, local TestRunner, the
candidate-compatible filter `integration_test,-large_ingestion_test,-acceptance_test`, observer,
`--max-seconds 1800`, fresh run id, fixture setup, and outcome-bearing teardown. Run it and observe
failure because the action is absent.

Assert `SERVICERADAR_TEST_SLOWEST` is absent. ExUnit's built-in report enables trace, forces
`max_cases: 1`, and disables timeouts, so it is allowed only in a separately labeled serial
non-cohort profiling run. Require the integration runner marker that reports max cases, trace, and
timeout mode.

Assert `BAZEL_PROFILE=ci`; template preflight and any `migrate_template` occur before `START_NS`;
the measured template check occurs after `START_NS` and cannot migrate; all four observer marker
paths are children of one private `mktemp -d` and are initially absent; and `END_NS` is assigned
immediately after teardown but before the stop marker or observer wait.

In the same source, add a deterministic mode that emits lowercase SHA-256 over the normalized
`IntegrationBenchmark` action block, both observer source files, and only the
`observe_connections` Bazel rule. Register that mode as a `py_binary` named
`//:integration_benchmark_harness_hash`; the hash deliberately excludes the evidence document and
the hash implementation itself.

- [ ] **Step 7: Add the explicit-only benchmark action**

Add an action whose trigger matches only branch `benchmark/parallel-core-integration`, with no PR
trigger and no merge checkout. Copy the current BazelCI image, pool, platform, credentials, full
build, guarded lifecycle, out-of-clock template preflight, and local TestRunner. At action start require
`SERVICERADAR_BENCHMARK_EXPECTED_SHA` and compare it to `git rev-parse HEAD`. Start the observer after
fixture materialization, wait at most 30 seconds for its ready marker, and only then start sweep.
The measured current-template check may not migrate; pending state classifies the invocation as
warm-up/non-cohort and still cleans up. After the suite, write the suite-complete marker, wait at
most 30 seconds for the quiescent marker, run teardown, and capture `END_NS` immediately when
teardown returns. Only then write the stop marker and wait for the observer. Print lifecycle timing
from `START_NS..END_NS`. Cleanup preserves the original suite status, observer status, and teardown
status. This action remains byte-identical through the after revision.

- [ ] **Step 8: Verify and commit the baseline**

Run:

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test //rust/integration-db:serviceradar_integration_db_test
git diff --check
openspec validate parallelize-core-integration-tests --strict
```

Commit only measurement files; the proposal and benchmark contract were frozen in the preceding
documentation commit and are deliberately not part of this instrumentation baseline:

```bash
git add rust/integration-db buildbuddy.yaml ci_heavy_gate_contract_test.py BUILD.bazel
git commit -m "test(ci): add controlled integration benchmark"
```

Immediately record `git rev-parse HEAD` in the SDD ledger as the before SHA, without creating
another tracked commit. Run
`bazel run -c opt --config=remote //:integration_benchmark_harness_hash` and record its single hash
line in the ledger. Task 2's behavior-changing commit must use this
commit as its direct parent. Task 8 copies the saved SHA/hash into `benchmark.md` before accepting
any cohort.

---

### Task 2: Make Ecto Sandbox ownership composable

**Files:**
- Modify: `elixir/serviceradar_core/test/support/test_support.ex`
- Modify: `elixir/serviceradar_core/test/support/data_case.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs`

**Interfaces:**
- Consumes: Ecto Sandbox owner/allow APIs and ExUnit context keys `:async`, `:sandbox`, and `:timeout`.
- Produces: `with_repo_owner(context, fun)`, `stop_repo_owner(owner, shared: boolean)`, `allow_sandbox(child_pid)`, and `validate_sandbox_allowance!(result, child_pid)`.

- [ ] **Step 1: Add red guard/API tests**

```elixir
test "async unboxed mode is rejected before pool mode changes" do
  assert_raise ArgumentError, ~r/async.*unboxed.*serial lane/s, fn ->
    TestSupport.checkout_repo!(%{async: true, sandbox: :unboxed})
  end
  assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
end

test "async callers cannot start a shared helper owner" do
  assert_raise ArgumentError, ~r/shared owner.*async/s, fn ->
    TestSupport.with_repo_owner(%{async: true}, fn -> flunk("must not run") end)
  end
  assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
end
```

Migrate all three existing calls to `with_repo_owner(%{async: false}, fn -> ... end)`. Resolve
`$SANDBOX_TARGET` with the exact recipe above, run the guarded focused-Sandbox lifecycle, and
observe red.

- [ ] **Step 2: Add red two-owner teardown coverage**

In a serial test, create a unique probe table through one explicitly unboxed checkout, restore
manual mode, and start two owner-runner processes. Each runner starts a non-shared owner and accepts
query/stop messages. Assert owner A's uncommitted insert is invisible to B; stop A through
`stop_repo_owner(owner, shared: false)`; assert B can still insert/query; then stop B. Before the
implementation this fails because the public local teardown does not exist and current teardown
resets all connections.

- [ ] **Step 3: Split shared and non-shared teardown**

```elixir
@doc false
def stop_repo_owner(owner, shared: false) do
  if Process.alive?(owner), do: Sandbox.stop_owner(owner)
  :ok
end

def stop_repo_owner(owner, shared: true) do
  try do
    drain_stateful_alert_engines()
    drain_dependency_dispatcher_tasks()
    drain_result_coordination_tasks()
    if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    :ok
  after
    Sandbox.mode(ServiceRadar.Repo, :manual)
  end
end
```

Reject async/unboxed before any pool operation. In the ordinary owner path compute
`shared? = not context[:async]`, pass it to `start_owner!`, and close over it in `on_exit`. Replace
`with_repo_owner/1` with context-required `with_repo_owner/2`; reject async context before starting
an owner and call the shared teardown clause in `after`.

- [ ] **Step 4: Add red allowance-result and visibility tests**

```elixir
for accepted <- [:ok, {:already, :allowed}] do
  assert :ok = TestSupport.validate_sandbox_allowance!(accepted, self())
end

for rejected <- [{:already, :owner}, :not_found, {:unexpected, :shape}] do
  assert_raise ArgumentError, ~r/sandbox.*allow/i, fn ->
    TestSupport.validate_sandbox_allowance!(rejected, self())
  end
end
```

Start a blocked test-owned child, allow it, insert a unique row in the parent transaction, and
assert the child sees it while a separate non-shared owner does not. Stop/await the child before the
owner.

- [ ] **Step 5: Implement and expose the allowance helper**

```elixir
def allow_sandbox(child_pid) when is_pid(child_pid) do
  ServiceRadar.Repo
  |> Sandbox.allow(self(), child_pid)
  |> validate_sandbox_allowance!(child_pid)
end

def validate_sandbox_allowance!(result, _child_pid)
    when result in [:ok, {:already, :allowed}], do: :ok

def validate_sandbox_allowance!(result, child_pid) do
  raise ArgumentError,
        "could not allow test-owned child #{inspect(child_pid)} in the SQL sandbox: #{inspect(result)}"
end
```

Expose it through DataCase and document that callers own and stop children. Document the complete
async eligibility and serial exception criteria.

- [ ] **Step 6: Verify and commit**

Resolve `$SANDBOX_TARGET`, run the exact guarded focused-Sandbox lifecycle above, then run:

```bash
cd elixir/serviceradar_core
mix format --check-formatted test/support/test_support.ex test/support/data_case.ex test/serviceradar/test_support_sandbox_test.exs
```

Expected: all focused tests PASS and B survives A's teardown. Commit:

```bash
git add elixir/serviceradar_core/test/support elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs
git commit -m "test(elixir): isolate concurrent sandbox owners"
```

---

### Task 3: Encode bounded concurrency and fixed-resource partitioning

**Files:**
- Modify: `build/integration_shards.bzl`
- Create: `build/integration_shards_test.bzl`
- Modify: `build/BUILD.bazel`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `elixir/serviceradar_core/test/test_helper.exs`
- Modify: `elixir/serviceradar_core/test/support/test_support.ex`
- Modify: `elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs`

**Interfaces:**
- Consumes: `partition_by_shard(srcs)` and generated shard targets.
- Produces: `INTEGRATION_MAX_CASES = 2`, `LARGE_INGESTION_DB_SHARD = "large_ingestion"`, `FIXED_EXTERNAL_RESOURCE_SHARD = "s7"`, `fixed_external_resource_sources()`, `integration_test_env(shard)`, and `integration_max_cases!(value)`.

- [ ] **Step 1: Write red Starlark topology tests**

Use `@bazel_skylib//lib:unittest.bzl` and assert:

```starlark
asserts.equals(env, 8, len(integration_shard_names()))
asserts.equals(env, 2, INTEGRATION_MAX_CASES)
asserts.equals(env, "large_ingestion", LARGE_INGESTION_DB_SHARD)
asserts.equals(env, "s7", FIXED_EXTERNAL_RESOURCE_SHARD)
```

Pass a synthetic list containing all three fixed sources plus eight ordinary sources to
`partition_by_shard`. Assert each fixed source occurs once in `s7`, zero times in `s0..s6`, and the
flattened buckets are a disjoint permutation of the input. Instantiate a
`test_suite(name = "integration_shards_test", ...)` in `build/BUILD.bazel`.

Also extend the Python contract with the three real fixed-resource files as declared data. Assert
each contains exactly one `use ServiceRadar.DataCase, async: false`. Assert the core BUILD uses
`integration_test_env(shard)` for generated integration targets and the `unit_tests` block contains
no `SERVICERADAR_INTEGRATION_MAX_CASES`.

- [ ] **Step 2: Run red**

Run
`bazel test -c opt --config=remote //build:integration_shards_test //:ci_heavy_gate_contract_test`.
Expected: FAIL because the constants/source class do not exist.

- [ ] **Step 3: Implement the Starlark contract**

```starlark
INTEGRATION_SHARD_COUNT = 8
INTEGRATION_MAX_CASES = 2
LARGE_INGESTION_DB_SHARD = "large_ingestion"
FIXED_EXTERNAL_RESOURCE_SHARD = "s7"

_FIXED_EXTERNAL_RESOURCE_SRCS = [
    "test/integration/netflow_ingestion_integration_test.exs",
    "test/integration/proxmox_api_smoke_integration_test.exs",
    "test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs",
]

def fixed_external_resource_sources():
    return list(_FIXED_EXTERNAL_RESOURCE_SRCS)

def integration_test_env(shard):
    return {
        "SERVICERADAR_ONLY_INTEGRATION": "1",
        "SERVICERADAR_INTEGRATION_MAX_CASES": str(INTEGRATION_MAX_CASES),
        "SERVICERADAR_TEST_DB_SHARD": shard,
    }
```

Make `partition_by_shard` fail if a classified source is absent, partition only remaining sources,
then append the three sources to `s7`. Retain both existing heavy hints in this task; Task 4 removes
ResultsRouter from `_HEAVY_SRCS` in the same commit that moves its slow case.

In the Starlark test, call `integration_test_env(shard)` for every value returned by
`integration_shard_names()` and assert cap `"2"`, the matching shard value, and an identical key set
across all eight dictionaries.

- [ ] **Step 4: Add red Elixir cap-parser tests**

```elixir
test "integration max cases accepts a positive integer" do
  assert TestSupport.integration_max_cases!("2") == 2
end

test "integration max cases fails closed" do
  for value <- [nil, "", "two", "0", "-1", "2x"] do
    assert_raise ArgumentError, ~r/SERVICERADAR_INTEGRATION_MAX_CASES.*positive integer/s, fn ->
      TestSupport.integration_max_cases!(value)
    end
  end
end
```

Run the sandbox shard and observe failure because the parser is absent.

- [ ] **Step 5: Implement parser and runner wiring**

```elixir
def integration_max_cases!(value) do
  case Integer.parse(value || "") do
    {count, ""} when count > 0 -> count
    _ -> raise ArgumentError, "SERVICERADAR_INTEGRATION_MAX_CASES must be a positive integer"
  end
end
```

Load `integration_test_env` in the core BUILD file and set every generated integration target's
`env = integration_test_env(shard)`. In the integration-only branch
of `test_helper.exs`, parse the environment before `ExUnit.start` and pass the result as `max_cases`.
Unit targets receive no override.

- [ ] **Step 6: Verify and commit**

```bash
bazel test -c opt --config=remote //build:integration_shards_test //:ci_heavy_gate_contract_test
bazel query --output=label 'tests(//elixir/serviceradar_core:integration_tests)'
git diff --check
```

Expected: exactly eight `integration_tests_sN` labels and passing tests. Commit:

```bash
git add build/integration_shards.bzl build/integration_shards_test.bzl build/BUILD.bazel BUILD.bazel ci_heavy_gate_contract_test.py elixir/serviceradar_core/BUILD.bazel elixir/serviceradar_core/test/test_helper.exs elixir/serviceradar_core/test/support/test_support.ex elixir/serviceradar_core/test/serviceradar/test_support_sandbox_test.exs
git commit -m "test(ci): bound integration concurrency topology"
```

---

### Task 4: Source-separate both ingestion release gates

**Files:**
- Create: `elixir/serviceradar_core/test/release_gates/large_ingestion/results_router_release_gate_test.exs`
- Create: `elixir/serviceradar_core/test/release_gates/large_ingestion/identifier_cardinality_release_gate_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/results_router_integration_test.exs`
- Delete: `elixir/serviceradar_core/test/serviceradar/inventory/identifier_cardinality_gate_test.exs`
- Modify: `elixir/serviceradar_core/BUILD.bazel`
- Modify: `rust/integration-db/BUILD.bazel`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`

**Interfaces:**
- Consumes: `LARGE_INGESTION_DB_SHARD`, ordinary integration runtime inputs, and `tests/provision_db_test.rs`.
- Produces: `//elixir/serviceradar_core:large_ingestion_release_gate` and `//rust/integration-db:provision_db_large_ingestion`.

- [ ] **Step 1: Extend the red target/separation contract without undeclared files**

Do not add nonexistent release source paths to Bazel `data` and do not attempt to read them yet.
Assert the current ordinary files still contain their named heavy cases, then require the future
target/provision/runtime separation in Python:

```python
self.assertIn('"test/release_gates/**"', core_build)
self.assertIn('name = "large_ingestion_release_gate"', core_build)
self.assertIn('"SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT": "50000"', core_build)
self.assertIn('"integration_test",', core_build)
self.assertIn('"large_ingestion_test",', core_build)
self.assertIn('name = "provision_db_large_ingestion"', integration_db_build)
self.assertIn('"SERVICERADAR_TEST_DB_SHARDS": LARGE_INGESTION_DB_SHARD', integration_db_build)
```

Run `//:ci_heavy_gate_contract_test` and observe red because the target/provision/source-exclusion
contract is absent. The failure must be an assertion failure, not a Bazel analysis error caused by
an undeclared or nonexistent data label.

- [ ] **Step 2: Move both suites without reducing behavior**

The router release module keeps the original large test, `setup_all`, application-env setup/restore,
`system_actor/0`, device-count/chunk parsing, `ceil_div/2`, IP generation, and `scalar_count!/2`. Name
it `ServiceRadar.ResultsRouterLargeIngestionReleaseGateTest`, keep DataCase `async: false`, and tag it
`:integration` plus `:large_ingestion`.

Move the identifier module intact to the release directory, retain `@devices 500`, `@rounds 3`, and
`async: false`, add `@moduletag :integration`, and update its documented Bazel invocation. Remove
only the large test and now-unused helpers/aliases from the ordinary ResultsRouter file. In this
same step remove the now-release-only ResultsRouter path from `_HEAVY_SRCS`.

After both destination files exist, add them to the root `py_test` data and extend the Python test
to read them. Require `50_000` in the router release source, `@devices 500` plus `@rounds 3` in the
cardinality release source, and neither ordinary source to contain its heavy test name. Do not
infer deletion of an undeclared path from inside a Bazel sandbox; Step 6 checks the actual working
tree. Run the contract again; it remains red until the dedicated Bazel and provision targets are
added.

- [ ] **Step 3: Extract shared runtime data and exclude release sources**

Lift the existing integration shard `data` expression into `INTEGRATION_RUNTIME_DATA`. It retains
the current `config/**`, `lib/**`, `priv/**`, non-test `test/**`, manifests, Wasm source groups,
config loader, and `//build:run_id_file`. Both ordinary targets and the dedicated gate consume it.
Exclude `test/release_gates/**` and the cold database-bootstrap integration source from
`ALL_TEST_SRCS`; exclude release test files from runtime data. The bootstrap source is moved intact
because its two serial startup passes already exceed the complete PR latency budget.

- [ ] **Step 4: Add the dedicated Elixir target**

```starlark
ex_unit_test(
    name = "large_ingestion_release_gate",
    size = "enormous",
    srcs = glob(["test/release_gates/large_ingestion/*_test.exs"], allow_empty = False) + [
        "test/serviceradar/cluster/database_bootstrap_integration_test.exs",
    ],
    data = INTEGRATION_RUNTIME_DATA,
    elixir_opts = [
        "-r", "test/db/integration_env.exs",
        "-r", "../../build/elixir_test_config_loader.exs",
        "-r", "test/test_helper.exs",
    ],
    env = {
        "SERVICERADAR_ONLY_INTEGRATION": "1",
        "SERVICERADAR_INTEGRATION_MAX_CASES": "1",
        "SERVICERADAR_TEST_DB_SHARD": LARGE_INGESTION_DB_SHARD,
        "SERVICERADAR_LARGE_INGESTION_DEVICE_COUNT": "50000",
        "SERVICERADAR_LARGE_INGESTION_CHUNK_SIZE": "1000",
    },
    tags = ["integration_test", "large_ingestion_test"],
    target_compatible_with = requires_shared_fixture(),
    deps = [":erlang_app"],
)
```

- [ ] **Step 5: Add the focused provision target**

Load `LARGE_INGESTION_DB_SHARD` and add a `rust_test` reusing `tests/provision_db_test.rs`,
`FIXTURE_DATA + ["//elixir/serviceradar_core:migrations"]`, existing lifecycle tags/deps/guard, and:

```starlark
env = {"SERVICERADAR_TEST_DB_SHARDS": LARGE_INGESTION_DB_SHARD}
```

Do not alter ordinary `provision_db`, which remains exactly `s0..s7`.

- [ ] **Step 6: Verify source separation and focused lifecycle**

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test //build:integration_shards_test
bazel query --output=label 'attr(tags, large_ingestion_test, tests(//...))'
test ! -e elixir/serviceradar_core/test/serviceradar/inventory/identifier_cardinality_gate_test.exs
```

Then run the guarded focused prepare/provision/test/teardown lifecycle with local TestRunner and
retries one. Expected: one tagged target, both full ingestion workloads plus the intact two-pass
cold bootstrap pass serially, teardown removes `<run>_large_ingestion`, and bootstrap leaves no
separately named scratch database. The newly introduced target/action/status names remain
permanent and stable.

- [ ] **Step 7: Commit**

```bash
git add elixir/serviceradar_core rust/integration-db/BUILD.bazel ci_heavy_gate_contract_test.py BUILD.bazel
git commit -m "test(ci): separate large ingestion release gates"
```

---

### Task 5: Promote only the audited transaction-isolated first wave

**Files:**
- Modify: `elixir/serviceradar_core/test/integration/advisory_feed_loader_integration_test.exs`
- Modify: `elixir/serviceradar_core/test/integration/secret_broker_audit_integration_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_rule_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/composite_checks/composite_check_input_test.exs`
- Modify: `elixir/serviceradar_core/test/serviceradar/composite_checks/device_composite_check_result_test.exs`
- Create: `elixir/serviceradar_core/test/ASYNC_INTEGRATION_AUDIT.md`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`

**Interfaces:**
- Consumes: non-shared owner teardown and cap `2` from Tasks 2-3.
- Produces: two explicit `use ServiceRadar.DataCase, async: true` modules, a four-file serial
  composite-check contract, and semantic audit evidence.

- [ ] **Step 1: Extend the contract test before module edits**

Add the advisory-feed-loader and secret-broker-audit paths to `ASYNC_SAFE_SRCS`. For each source
assert one
`use ServiceRadar.DataCase, async: true`; reject `sandbox: :unboxed`, `Application.put_env`,
`Application.delete_env`, `TRUNCATE`, `CREATE TABLE`, `REFRESH MATERIALIZED`, `Gnat.`, and `Nats`.
Add the four composite-check paths to an independent required-serial set and assert they remain
`async: false`. Assert both sets are disjoint from fixed-resource sources. Run the test and observe
red because the two eligible modules are serial.

- [ ] **Step 2: Write the semantic audit record**

For each promoted file record: writes stay inside its DataCase owner; identifiers are unique; there
is no DDL/unboxed/global mutation/external service/global DB worker; and no child allowance is
required. Record these serial decisions:

- credential event writer: application env mutation;
- credential broker grant lifecycle: `setup_all` core startup mutates application config;
- ordinary ResultsRouter: three application env mutations;
- first-user role: unboxed plus `TRUNCATE` plus true multiple connections;
- onboarding package atomicity: unboxed plus global crypto config and lock visibility;
- remote access sessions: application config, task concurrency, committed cleanup;
- composite checks: the `CompositeCheck -> ScheduleNotifier -> EvaluationWorker.cancel ->
  Oban.cancel_all_jobs/1` path mutates globally shared Oban state, so all four modules remain
  serial;
- NetFlow ingestion, ad-hoc scan NATS E2E, Proxmox smoke: fixed external `s7` lane.

- [ ] **Step 3: Make the two one-line promotions**

Change only `async: false` to `async: true` in advisory feed loader and secret broker audit. Keep
all four composite-check modules serial under the independent static contract. Do not promote
Rollup or RemoteAccessHostKeys in this first wave, and never allow an application-supervised
process into a test owner's transaction.

- [ ] **Step 4: Run two retry-free stress waves**

With one guarded `s0..s7` provision, run the ordinary wildcard twice sequentially using
`--flaky_test_attempts=1` and `--test_output=all`, with built-in slowest reporting absent. Require
each shard's runner marker to show `max_cases: 2`, trace off, and timeouts enabled, then teardown.
Expected: both pass with no ownership/deadlock/checkout-drop output. Verify fixed external files
are sourced only by `integration_tests_s7`.

- [ ] **Step 5: Verify and commit**

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test //build:integration_shards_test
cd elixir/serviceradar_core
mix format --check-formatted test/integration/advisory_feed_loader_integration_test.exs test/integration/secret_broker_audit_integration_test.exs test/serviceradar/composite_checks/*.exs
```

Expected: PASS. Commit:

```bash
git add elixir/serviceradar_core/test ci_heavy_gate_contract_test.py BUILD.bazel
git commit -m "test(elixir): enable audited integration concurrency"
```

---

### Task 6: Update ordinary CI and add the independent heavy action

**Files:**
- Modify: `buildbuddy.yaml`
- Modify: `ci_heavy_gate_contract_test.py`

**Interfaces:**
- Consumes: observer/provision/test targets from Tasks 1 and 4.
- Produces: ordinary filter `integration_test,-large_ingestion_test,-acceptance_test` and action/status context `LargeIngestionGate`.

- [ ] **Step 1: Add red action assertions**

Extend the Python action-block parser. BazelCI must have the negative heavy tag, retries one, local
TestRunner, observer with `--max-seconds 1800`, effective-runner output, run id, fixture materialization, and
outcome-bearing teardown. Assert its preflight/migration is before `START_NS`, its measured phase
does not migrate, its markers begin absent beneath a private directory, and `END_NS` is captured
immediately after teardown and before observer shutdown.
`LargeIngestionGate` must have:

```yaml
push:
  branches:
    - "staging"
  tags:
    - "v*"
schedule:
  crons:
    - "0 2 * * *"
```

Require only sweep, prepare, conditional migration, `provision_db_large_ingestion`,
`large_ingestion_release_gate`, observer, and teardown. Reject ordinary `provision_db` and the
`//...` integration wildcard inside this block. Run and observe red.

- [ ] **Step 2: Update ordinary selection and measurement**

Change only the ordinary integration wildcard to:

```text
--build_tests_only
--build_tag_filters=integration_test,-large_ingestion_test,-acceptance_test
--test_tag_filters=integration_test,-large_ingestion_test,-acceptance_test
//...
```

The build and test filters must remain identical. `--test_tag_filters` alone prevents execution but
does not keep unrelated top-level wildcard targets out of the measured build graph.

Use `--test_output=all` and require `SERVICERADAR_TEST_SLOWEST` to be absent from its suite. Record a
nanosecond start immediately before measured fixture materialization, after the separate template
preflight has completed. Start the observer after materializing fixture config and before sweep.
Poll its ready file for at most 30 seconds while also checking that the observer process is alive; a
missing marker, early exit, or deadline fails before sweep starts. The in-clock template check is
current-only and never runs `migrate_template`.

- [ ] **Step 3: Preserve suite, observer, and teardown outcomes**

Replace the simple trap with an inline cleanup function. It captures `$?`, removes the EXIT trap,
then writes the suite-complete marker and waits for the observer's two-sample quiescent marker.
Whether that bounded wait succeeds or fails, cleanup records the result and still attempts
teardown and captures `END_NS` immediately on its return. It then writes the stop marker, waits for
the observer, and removes only its `mktemp` paths, prints lifecycle seconds from
`START_NS..END_NS` plus the observer summary, then exits with original suite status if
non-zero, otherwise observer status if non-zero, otherwise teardown status. A teardown failure must
turn a green suite red.

- [ ] **Step 4: Add `LargeIngestionGate`**

Copy the current runner image, `workflows` pool, self-hosted/platform/resources, Harbor auth,
fixture materialization, credential forwarding, run-id, template check, local TestRunner, observer,
and cleanup contract. Use the trigger form above. Provision only
`//rust/integration-db:provision_db_large_ingestion` and run only:

```text
bazel test $FLAGS //elixir/serviceradar_core:large_ingestion_release_gate
```

Do not provision `s0..s7` or use an integration `//...` wildcard.

- [ ] **Step 5: Prove benchmark harness identity did not drift**

Hash the normalized `IntegrationBenchmark` action block, observer sources, and observer Bazel rule
at the before revision and current tree. Assert hashes match exactly. Do not include `benchmark.md`,
because recording evidence changes that document without changing the harness. If shared lifecycle cleanup needs a fix after the baseline commit,
apply the same measurement-only commit to both benchmark revisions and redefine the before revision
as its direct parent before behavior changes; never compare different harnesses.

Use the exact checked-in command at the current tree and compare its single output line to the hash
saved after Task 1:

```bash
bazel run -c opt --config=remote //:integration_benchmark_harness_hash
```

- [ ] **Step 6: Verify and commit**

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test
git diff --check
```

Expected: PASS; manual review confirms tags use `push.tags`, not a `v*` branch. Commit:

```bash
git add buildbuddy.yaml ci_heavy_gate_contract_test.py
git commit -m "ci: split large ingestion workflow gate"
```

---

### Task 7: Require newest exact-SHA heavy evidence for release

**Files:**
- Create: `build/ci/large_ingestion_gate_contract.v1`
- Create: `build/ci/large_ingestion_gate.py`
- Create: `build/ci/wait_for_large_ingestion_gate.py`
- Create: `build/ci/wait_for_large_ingestion_gate_test.py`
- Create: `build/ci/BUILD.bazel`
- Modify: `.github/workflows/release.yml`
- Modify: `ci_heavy_gate_contract_test.py`
- Modify: `BUILD.bazel`

**Interfaces:**
- Consumes: `steps.source.outputs.commit`, fetched `origin/staging`, GitHub's classic commit-status
  REST API through argv-only `gh api`, and context `LargeIngestionGate`.
- Produces: `//build/ci:wait_for_large_ingestion_gate`, a permanent introduction marker, and a
  30-minute fail-closed qualifier that permits only genuinely pre-marker historical tags.

- [ ] **Step 1: Write red pure behavior tests**

Create the library and test target first. Drive the implementation through injected git/status
adapters and a fake monotonic clock. Cover all of these cases:

- marker absent and release is a strict ancestor of introduction -> `HISTORICAL_NOT_APPLICABLE`;
- marker absent and introduction is an ancestor of release (including equality) ->
  contract-deletion error;
- marker absent and neither is an ancestor of the other -> divergent-history error;
- introduction lookup absent/repeated, shallow or unresolved history, malformed base marker, or git
  returning any result other than the documented 0/1 ancestry outcomes -> error;
- marker present but target or action missing -> error before polling;
- marker-bearing feature commit that is an ancestor of staging but predates the first-parent merge
  introduction -> applicable, not historical;
- older success followed by newer pending -> pending, ordered by `(created_at, id)`;
- newest `failure`, `error`, unknown state, or malformed success URL -> immediate error;
- newest success with exact HTTPS host `carverauto.buildbuddy.io` and nonempty
  `/invocation/<id>` path -> success; prefix/hostname spoofing -> error;
- pagination, wrong-context filtering, timestamp/id tie breaking, malformed JSON, and API command
  failure;
- missing/pending status reaches the injected 1,800-second deadline -> timeout error.

Do not stop at policy tests with a fake status source. Exercise the concrete `GhStatusClient` with
an injected subprocess runner that returns the exact multi-page `gh --slurp` JSON shape, nonzero
exit, malformed JSON, and malformed status records; assert its argv includes `--paginate`,
`--slurp`, and the exact full-SHA statuses endpoint and never uses a shell. Exercise the concrete
git adapter with an injected runner and assert every command is `git -C <workspace> ...`.

Run `bazel test -c opt --config=remote //build/ci:wait_for_large_ingestion_gate_test` and observe red
because the state machine and polling API do not exist.

- [ ] **Step 2: Implement fail-closed applicability and polling**

The marker file contains exactly `large-ingestion-gate-contract-v1`. The CLI verifies the release
commit and fetched base ref resolve, verifies release is an ancestor of the base, requires the base
tree to contain that exact marker, then discovers the marker addition with the equivalent of:

```text
git log --first-parent --reverse --diff-filter=A --format=%H origin/staging -- build/ci/large_ingestion_gate_contract.v1
```

Resolve `<workspace>` only from `BUILD_WORKSPACE_DIRECTORY` set by `bazel run`; missing or invalid
workspace state fails. Pass it explicitly with `git -C` for every git operation so the binary does
not depend on the Bazel runfiles/current-working directory.

Require exactly one nonempty introduction SHA; repeated addition indicates marker deletion/re-add
and fails. Inspect the immutable tree with `git cat-file`/`git show`
without `|| true`. If the marker is absent, evaluate both ancestry directions with explicit exit
handling. Introduction ancestor of release (including equality) means deletion/corruption; release
strictly ancestor of introduction means truly historical; neither direction means a divergent
commit and fails closed; any git exit other than 0/1 fails. If the marker is present, require its
exact contents plus both
`name = "large_ingestion_release_gate"` in the core BUILD and `name: "LargeIngestionGate"` in
`buildbuddy.yaml` before any API request.

Invoke `gh api --paginate --slurp
/repos/<repository>/commits/<commit>/statuses?per_page=100` with an argv list and `shell=False`,
mapping the value read from the named token variable to `GH_TOKEN` only in the child environment. Parse the JSON in Python,
flatten the pages, filter the exact context, parse `created_at` as UTC time, parse `id` as an
integer, and select the maximum `(created_at, id)`. Poll missing/pending every 15 seconds until a
monotonic 1,800-second deadline. Validate success URLs with `urllib.parse`: scheme `https`, hostname
exactly `carverauto.buildbuddy.io`, and a nonempty id under `/invocation/`. Never fall back to an
older success. Do not log the token, request environment, headers, or credentials.

- [ ] **Step 3: Register and verify the Bazel executable**

Register one `py_library`, one `py_binary`, and one `py_test` in `build/ci/BUILD.bazel`; export the
marker as a declared source. The CLI surface is exact:

```text
--repository carverauto/serviceradar
--commit <full-sha>
--base-ref origin/staging
--token-env GH_TOKEN
--timeout-seconds 1800
--poll-seconds 15
--target-url-prefix https://carverauto.buildbuddy.io/invocation/
```

Run the focused test and require every case from Step 1 to pass.

- [ ] **Step 4: Add red workflow/static-contract assertions**

Extend root test data with the marker, `build/ci/BUILD.bazel`, qualifier sources, and test. Require
`fetch-depth: 0`, `statuses: read`, exact marker contents, marker data dependencies on binary/test,
the Bazel target and CLI arguments, and strict workflow ordering:

```text
Enforce release source
  < Cache Bazel artifacts
  < Configure BuildBuddy remote cache
  < Install Bazelisk
  < Wait for large-ingestion gate
  < Install Cosign / Install ORAS / artifact publication
```

Reject inline `git show`/grep applicability, `gh api`, `jq`, or a missing-introduction/
missing-contract success shortcut in the release step. The Python qualifier may invoke `gh` only
through argv without a shell. Run `//:ci_heavy_gate_contract_test` and observe red because the
workflow does not yet invoke the qualifier.

- [ ] **Step 5: Invoke qualification before release tooling**

Add `statuses: read`. Immediately after `Install Bazelisk`, add:

```yaml
- name: Wait for large-ingestion gate
  env:
    RELEASE_COMMIT: ${{ steps.source.outputs.commit }}
  run: |
    set -euo pipefail
    bazel run ${BAZEL_BUILD_FLAGS} //build/ci:wait_for_large_ingestion_gate -- \
      --repository "${GITHUB_REPOSITORY}" \
      --commit "${RELEASE_COMMIT}" \
      --base-ref origin/staging \
      --token-env GH_TOKEN \
      --timeout-seconds 1800 \
      --poll-seconds 15 \
      --target-url-prefix https://carverauto.buildbuddy.io/invocation/
```

This remains before Cosign/ORAS installation, metadata resolution, any artifact build, and
publication. The earlier source-enforcement step already fetches `origin/staging` and verifies the
release commit is its ancestor; the qualifier independently fails if the referenced objects or
marker introduction cannot be resolved.

- [ ] **Step 6: Verify and commit**

```bash
bazel test -c opt --config=remote //build/ci:wait_for_large_ingestion_gate_test //:ci_heavy_gate_contract_test
git diff --check
git add build/ci .github/workflows/release.yml ci_heavy_gate_contract_test.py BUILD.bazel
git commit -m "ci(release): require large ingestion status"
```

Expected: PASS.

---

### Task 8: Rebalance, run paired cohorts, and close the change

**Files:**
- Modify: `build/integration_test_dispositions.bzl`
- Modify: `build/integration_shards.bzl`
- Modify: `build/integration_shards_test.bzl`
- Modify: `build/integration_selection_equivalence_test.exs`
- Modify: `build/BUILD.bazel`
- Modify: `openspec/changes/parallelize-core-integration-tests/benchmark.md`
- Modify: `openspec/changes/parallelize-core-integration-tests/tasks.md`
- Modify only if evidence demands reclassification: the two promoted files and four audited serial
  composite-check files.

**Interfaces:**
- Consumes: the database-free ExUnit selected-identity manifest, BuildBuddy timings, observer JSON,
  and all implemented targets.
- Produces: an exact manifest-backed serial placement, all attempt rows, accepted 20-run
  before/after cohorts, final decision, and evidenced checklist.

- [x] **Step 1: Write red structural-balance and manifest-equivalence contracts**

Extend the topology contract to require serial source counts
`[26, 22, 21, 22, 22, 23, 23]`. Extend the database-free selection-equivalence test to reject a
missing or stale `SERIAL_INTEGRATION_SELECTED_TEST_COUNTS` projection by comparing it exactly with
the real filtered `(source, module, test-name)` union. Observe RED: the old module-count partition
returns `[23, 23, 23, 23, 23, 22, 22]`, and the projection is absent.

- [x] **Step 2: Rebalance from selected-test identity counts**

Check in one positive exact selected-test count for every serial source and verify it against the
database-free selection runner. Assign sources by deterministic descending
`1 + selected_serial_test_identity_count` to the least structurally loaded serial lane; use source
count and lane name as tie-breakers. Keep all fixed-resource sources preseeded in `serial_0`.
Require selected-test counts `[185, 190, 189, 188, 188, 188, 188]`, structural loads
`[211, 212, 210, 210, 210, 211, 211]`, reverse-input determinism, and exact/disjoint membership.
Historical or current runtime durations do not enter the weight.

- [ ] **Step 3: Publish the structural-map candidate**

Commit the rebalancing and record its full SHA as the structural-map candidate, not yet the final
after revision. Record the benchmark and CPU-input hashes. Because BuildBuddy can execute only
commits reachable from GitHub, obtain user
authorization for an explicit feature-branch push if it has not already been granted. Any push uses:

```bash
git push github proposal/parallelize-integration-tests:refs/heads/proposal/parallelize-integration-tests
```

Verify output says `-> proposal/parallelize-integration-tests`, never `-> staging`.

- [ ] **Step 4: Run the exact-SHA trace-free safety smoke**

Run one retry-free `IntegrationBenchmark` against the structural-map candidate. Require exactly one
async lane at cap eight, seven serial lanes at cap one, pool size 12, finite timeouts, trace off,
current template, successful observer and outcome-bearing teardown, no residue or safety error,
measured lifecycle at most 90 seconds, and runtime serial-lane skew at most 1.5. If balance still
fails, stop and amend the proposal before collecting any timing-derived source profile; do not hand
move sources from the failing lane.

- [ ] **Step 5: Select the explicit CPU request**

Run five alternating attempts each at explicit 2 CPU and 12 CPU with the final structural map and
Repo pool 12. Twelve CPU is selectable only if all five attempts are safety-clean. If both are
selectable, choose 12 only when its median is at least 10% lower; if neither is selectable, stop.
Apply the winner identically to production `BazelCI` and both authoritative benchmark revisions.

- [ ] **Step 6: Freeze and smoke the final after SHA**

Commit the CPU winner and all evidence-only documentation, record the full SHA and harness/input
hashes, push it with the same explicit feature-branch refspec, then run one final exact-SHA smoke.
Any behavior or harness change creates a new candidate and requires this step again.

- [ ] **Step 7: Trigger alternating exact-SHA pairs**

Use BuildBuddy `ExecuteWorkflow` for `IntegrationBenchmark`, explicit before/after commit, expected
SHA environment, `async: false`, and `disable_retry: true`. Alternate one before then one after,
never overlap attempts, until each revision has 20 consecutive successful lifecycle attempts. Add
every started attempt, including failed sequences and censored teardown rows, to `benchmark.md`.
Use the exact curl payload in `benchmark.md`: set `BENCHMARK_SHA` to the selected full SHA before
each request, keep shell tracing disabled, record the returned invocation, and do not launch the
paired request until the prior workflow has completed.

If an after-cohort failure requires a behavior change, commit the fix, treat that full SHA as a new
after revision, recheck/push it under the same explicit authorization, and restart the after
sequence. Retain superseded rows with their original SHA. Keep an already accepted before cohort
unless the harness changes; any harness change must be applied identically to both revisions and
invalidates both accepted sequences.

- [ ] **Step 8: Evaluate every gate**

Calculate accepted-cohort median, nearest-rank p95 (ordered value 19), relative delta, every after
run's max/min non-empty shard ratio, maximum sampled run/fixture connections, live usable slots,
and pre-teardown zero samples. Required: after p95 <= 90.0 s; 20/20 retry-free pass in both cohorts;
every after skew <= 1.5; run peak <= 144; fixture peak <= `floor(usable slots * 0.90)`; zero ownership,
deadlock, process/database leak, or teardown failure; exactly one async plus seven serial lanes;
unchanged pool sizes.

- [ ] **Step 9: Exercise the heavy lifecycle and candidate status**

Run the focused provision/gate/teardown sequence at least three times with fixed CI values. Execute
`LargeIngestionGate` explicitly for the exact after commit and record its BuildBuddy
invocation/status. Verify both suites pass and no matching database remains. A successful
feature-branch status is pre-merge evidence for the exact candidate; it is not evidence that the
`staging` push trigger works.

After merge, verify the first applicable `staging` commit receives a successful
`LargeIngestionGate` status from the default-branch trigger and record that URL. This post-merge
observation does not block opening the implementation PR; leave OpenSpec task 5.6 (and any wording
that specifically claims default-branch publication) unchecked until that evidence exists.

- [ ] **Step 10: Run fresh repository verification and request final review**

```bash
bazel test -c opt --config=remote //:ci_heavy_gate_contract_test //build:integration_shards_test //build/ci:wait_for_large_ingestion_gate_test //rust/integration-db:serviceradar_integration_db_test
make lint
make test
git diff --check
openspec validate parallelize-core-integration-tests --strict
```

Expected: every command exits 0. Change `[ ]` to `[x]` only where implementation and required
external evidence exist. Run a fresh spec-compliance review followed by code-quality review;
resolve findings through the implementer and reviewer loop, rerun affected verification, and
commit:

```bash
git add build/integration_shards.bzl openspec/changes/parallelize-core-integration-tests
git commit -m "docs(openspec): record parallel integration acceptance"
```

Do not open a PR or mark the change complete until exact candidate status evidence exists and the
user authorizes the external operation.
