# Plan: make `docker_utils` own the container lifecycle for the dgraph acceptance test

Verified against the vendored `docker_utils-0.3.2` and `wait_utils-0.1.7`, and against the
`cmdb` gRPC integration test used as the reference shape.

Two corrected premises:

1. **`wait_until_ready_async` is not part of the answer and is being removed.** It cannot be
   reached from `wait_for_container`, which is synchronous, so a container fixture can never
   be *configured* with it -- the caller sets `WaitStrategy::NoWait` and runs the wait
   itself, which is exactly the state the dgraph test is in.
2. **`WaitStrategy` is a shared vocabulary with two drivers, not one.** `docker_utils` applies
   it synchronously to containers; `service_utils` applies it asynchronously to locally
   started binaries (`ServiceStartConfig::wait_strategy`). This is the fact the previous draft
   missed, and it changes what may be added and what may be removed.

---

## 0. What the `cmdb` blueprint establishes

```rust
let (pg_container_id, _) = docker_util.setup_container(&postgres_db_container_config()).unwrap();
// ... use the service ...
docker_util.stop_container(&pg_container_id, true).unwrap();
```

Four properties, each of which the dgraph test currently violates:

| Blueprint property | dgraph test today |
|---|---|
| The test never waits. `setup_container` returns ready or errors. | ~180 lines of retry loop, liveness check and diagnostics |
| The container spec is a named function in a **separate crate** (`container_specs_postgres`) | a private fn in the test file |
| Failures explain themselves; the test does no `docker inspect` scraping | `dump_diagnostics` re-implements `docker inspect` + `docker logs` |
| The body is linear: act, `assert!(result.is_ok())`, next | `scenario`/`scenario_async` wrappers over `Result<(), String>` |

And one property that is a **hazard**, not a model to copy blindly -- see §3.3.

## 1. What is actually wrong with the test today

Of 528 lines in [rust/dgraph-client/tests/dgraph_container_test.rs](rust/dgraph-client/tests/dgraph_container_test.rs), roughly 180 are fixture
infrastructure that belongs in `docker_utils`:

| Test code | Lines | Why it exists |
|---|---|---|
| `wait_until_ready_async` call + `probe_once` + `ProbeFailure` | 215-222, 330-344 | the config says `NoWait`, so the test waits |
| `classify()` incl. the container-liveness check | 275-306 | nothing aborts a wait when the container dies |
| `dump_diagnostics` at setup-failure time | 145-158, 191-202 | `--rm` reaps the container before the caller can look |
| `step!` / `START` / `elapsed_secs` | 40-56 | no visibility into what the crate is doing |
| `READY_TIMEOUT` / `READY_RETRY_DELAY` | 84-85 | readiness policy that should be config |
| the 30-line comment justifying `NoWait` | 108-131 | documents a gap, not a decision |

Three further defects, all invisible until CI is loaded:

1. **`docker` is `Copy` and threaded through `run_scenarios` -> `classify`** purely so the
   retry loop can ask whether the container is still alive. Crate work leaking into test
   signatures. The blueprint's test never touches `DockerUtil` after `setup_container`.
2. **The reuse path silently skips readiness entirely.** `get_or_start` returns at
   [start.rs:51](third_party/crates/docker_utils-0.3.2/src/docker/start.rs#L51) via `get_running_container` **without calling `wait_for_container`**. With
   `reuse_container(true)` plus `test.recycle-runner: true`, a container left behind by a
   killed run is handed straight back. Today the test's own loop covers this by accident;
   move readiness into the strategy without fixing this and the gate disappears on exactly
   the runner it matters on. The blueprint relies on this path (`setup_container` on a
   reusable postgres) and is exposed to the same hole.
3. **Teardown can fail on a corpse.** `stop()` ([stop.rs:27](third_party/crates/docker_utils-0.3.2/src/docker/stop.rs#L27)) errors with `Container doesn't exists`
   when the container is already gone -- which is what `--rm` guarantees after an OOM. The
   blueprint's `assert!(result.is_ok())` on `stop_container` would fail for that reason alone.

## 2. Exact gaps in `docker_utils` / `wait_utils`

| # | Gap | Where | Consequence |
|---|---|---|---|
| **G1** | No caller-supplied readiness predicate in `WaitStrategy` | `enum_wait_strategy.rs` | Dgraph accepts reads ~4s before it accepts an `Alter`; every built-in gate opens too early, so the caller writes the loop |
| **G2** | A wait never checks whether the container is still alive | [start.rs:235-291](third_party/crates/docker_utils-0.3.2/src/docker/start.rs#L235-L291) | an OOM two seconds into a 120s wait reports a **timeout** -- symptom, not cause. The ADLR's two-day failure |
| **G3** | `container_diagnostics()` is never called internally | added in 0.3.2, zero callers | only the crate can collect a post-mortem before `--rm` reaps the container |
| **G4** | Reuse path bypasses the wait strategy | [start.rs:51](third_party/crates/docker_utils-0.3.2/src/docker/start.rs#L51), and `:72` after the "is starting" branch | a reused/stale container is returned unverified |
| **G5** | `WaitForGrpcHealthCheck` is a *driver-specific* variant with no marking | [start.rs:286-288](third_party/crates/docker_utils-0.3.2/src/docker/start.rs#L286-L288) (`"for yet supported"`) | **live and correct under `service_utils`**, always-fails under `docker_utils`. Nothing in the type says which |
| **G6** | `build(dbg)` calls `exit(42)` when the daemon is unreachable | [build.rs:28](third_party/crates/docker_utils-0.3.2/src/docker/build.rs#L28) | a library terminates the test process; Bazel sees exit 42 and no `Result` ever surfaces |
| **G7** | `pull()` panics with an empty message on spawn failure | [pull.rs:76](third_party/crates/docker_utils-0.3.2/src/docker/pull.rs#L76) | `panic!("")` -- no diagnostic at all |
| **G8** | `stop()` errors when the container is already gone | [stop.rs:27](third_party/crates/docker_utils-0.3.2/src/docker/stop.rs#L27) | teardown failure masks the real failure |
| **G9** | `--rm` is unconditional | [utils_test.rs:44](third_party/crates/docker_utils-0.3.2/src/utils_test.rs#L44) | no way to keep a corpse for inspection; makes G3 mandatory rather than convenient |
| **G10** | `check_if_container_is_starting` treats "has any log output" as starting | [utils.rs:22-48](third_party/crates/docker_utils-0.3.2/src/docker/utils.rs#L22-L48) | a container that logged once and died reads as starting |

### G5 restated -- do not remove `WaitForGrpcHealthCheck`

The previous draft called it dead and proposed deleting it. The blueprint disproves that:

```rust
WaitStrategy::WaitForGrpcHealthCheck(url, 10)   // -> ServiceStartConfig, driven by service_utils
```

`service_utils::start_service_from_config` is `async`, so it *can* await
`wait_until_grpc_health_check`. The variant is correct there and in use. What is wrong is
that **`WaitStrategy` carries variants only one of its two drivers can honour, and the type
says nothing about it.** `docker_utils` stubs the one it cannot run; a future variant that
only `docker_utils` can run would force the same stub into `service_utils`.

The rule this imposes on G1: **any new variant must be honourable by both drivers.** That is
the real design constraint, and it is what §3 is built around.

## 3. Design: how to express the probe

### 3.1 Not generics

The obvious move -- `WaitStrategy<P: ReadinessProbe>` with `P = NoProbe` -- does not compile
for existing callers:

> **Default type parameters do not participate in inference.** They apply in *type position*
> only. `let config = ContainerConfig::builder()...wait_strategy(WaitStrategy::NoWait).build();`
> leaves `P` unconstrained and fails with `E0282: type annotations needed`. Falling back to
> the default is `#![feature(default_type_parameter_fallback)]`, still unstable.

So it is a source break for every existing caller -- including `container_specs_postgres`,
`ServiceStartConfig`, and both crates' doc examples -- and it threads `P` through nine public
signatures in `docker_utils` plus every `service_utils` signature that names a strategy.

### 3.2 A function pointer plus a context struct

```rust
// wait_utils/src/types/probe_context.rs
/// What the driver knows about the thing being waited on, handed to the probe each attempt.
///
/// The probe needs an address to talk to, and only the driver knows the final one. Passing it
/// in is what removes the need for the probe to capture anything -- which is what keeps
/// `WaitStrategy` a plain data enum, and what lets both drivers supply it.
#[derive(Debug, Clone, Eq, PartialEq, Hash)]
pub struct ProbeContext { id: String, host: String, port: u16, attempt: u32 }

// wait_utils/src/types/enum_wait_strategy.rs
/// One readiness attempt. `Probe<(), String>`: a strategy answers "is it ready", it does not
/// build the caller's client.
pub type ProbeFn = fn(&ProbeContext) -> Probe<(), String>;

pub enum WaitStrategy {
    NoWait,
    WaitForDuration(u64),
    WaitUntilConsoleOutputContains(String, u64),
    WaitForHttpHealthCheck(String, u64),
    /// Async-driver only (`service_utils`). `docker_utils` cannot apply it -- see G5.
    WaitForGrpcHealthCheck(String, u64),
    /// Honoured by both drivers. The probe is synchronous by contract; see 3.3.
    WaitUntilReady { probe: ProbeFn, timeout_secs: u64, retry_delay_ms: u64 },
}
```

Why this:

- **`fn` pointers implement `Debug`, `Clone`, `Copy`, `PartialEq`, `Eq`, `PartialOrd`, `Ord`
  and `Hash`.** `WaitStrategy` keeps every derive, and so do `ContainerConfig` and
  `ServiceStartConfig`, which merely hold one. That is exactly the property a `Box<dyn Fn>`
  would destroy -- and the reason the current test comment gives for not doing this at all.
- **No generic threading, no public signature changes, purely additive.**
- **Not `dyn`.** Satisfies the static-dispatch convention in [rust/README_RUST.md](rust/README_RUST.md) §6.
- **`ProbeContext.attempt`** lets a probe escalate to `Probe::Fatal` after N without a `Cell`.
- **Both drivers can run it**, which is the G5 constraint -- subject to 3.3.

The probe cannot capture state. For a fixture it does not need to: the address is the state
and the context carries it. A probe needing more (token, cert path) reads a `const`/`static`
or the environment.

### 3.3 The blueprint's hazard: `setup_container` inside `#[tokio::test]`

The previous draft argued a sync probe may freely build a runtime because "`setup_container`
is sync and never runs inside a runtime". **The blueprint disproves that** -- it calls
`docker_util.setup_container(...)` from inside `#[tokio::test]`. A probe doing
`Runtime::new().block_on(..)` there panics with *"Cannot start a runtime from within a
runtime"*, and `block_in_place` is not an escape either (`#[tokio::test]` is current-thread
by default, where it also panics).

This is not the probe author's problem to rediscover once per probe. **The driver owns it:**

- **D9** -- `docker_utils` runs the `WaitUntilReady` loop on a dedicated `std::thread` and
  joins it. The probe is then guaranteed no ambient runtime and may build its own freely.
  Everything moved is `Send`: `ProbeFn` is a fn pointer, `ProbeContext` owns its strings,
  `DockerUtil` is `Copy`. Cost: one thread per `setup_container`.
- `service_utils` does the same from its async loop (`spawn_blocking`, or the same dedicated
  thread), so the sync contract holds identically under both drivers.

Documented once in the crate, this is what makes `WaitUntilReady` honourable by both drivers
instead of becoming the next `"for yet supported"`.

## 4. Work items

### `wait_utils` 0.1.8

- **W1** Add `ProbeContext`, `ProbeFn`, `WaitStrategy::WaitUntilReady`.
- **W2** Remove `wait_until_ready_async`. **Keep** `WaitForGrpcHealthCheck` and
  `wait_until_grpc_health_check` -- `service_utils` uses them (G5). Document per-variant which
  drivers honour it.
- **W3** *(recommended)* Re-express `wait_until_console_output` / `wait_until_http_health_check`
  as one-shot predicates (`console_output_contains(id, needle) -> bool`,
  `http_check_ok(url) -> bool`) and let the drivers compose them with `wait_until_ready`. This
  is what makes G2 apply to *every* strategy instead of only the new one, and deletes two
  hand-written retry loops.
- **W4** Tests, no Docker needed: ready after N attempts; a `Fatal` probe stops on attempt 1;
  a timeout reports the probe's last error, not a placeholder.

### `docker_utils` 0.3.3

- **D1 (G1)** Dispatch `WaitUntilReady` from `wait_for_container` via `wait_until_ready`.
  `wait_for_container` needs host and port to build the `ProbeContext`; it currently takes
  only `(container_id, wait_strategy)`. It is `pub(crate)` -- no public break.
- **D2 (G2)** Check liveness between attempts, for **every** strategy:
  ```rust
  // Only `Ok(false)` aborts. An `Err` means docker did not answer, which is not evidence the
  // container died -- treating it as death would fail a healthy run on a transient hiccup.
  if matches!(self.check_running(container_id), Ok(false)) {
      return Probe::Fatal(format!("container '{container_id}' stopped while waiting"));
  }
  ```
- **D3 (G3)** On any wait failure, attach the post-mortem before returning:
  ```rust
  Err(e) => {
      let detail = match self.diagnostics(container_id, 200) {
          Ok(d) if d.looks_oom_killed() =>
              format!("{e}\ncontainer was OOM-killed -- raise the memory limit\n{d}"),
          Ok(d)  => format!("{e}\n{d}"),
          Err(_) => format!("{e} (diagnostics unavailable: container already removed)"),
      };
      return Err(DockerError::from(detail));
  }
  ```
- **D4 (G4)** Call `wait_for_container` on the reuse path ([start.rs:51](third_party/crates/docker_utils-0.3.2/src/docker/start.rs#L51)) and after the
  "already starting" branch (`:72`). Without this, moving readiness into the config makes the
  recycled-runner case *worse* than today -- and the blueprint's reusable-postgres pattern is
  equally exposed.
- **D5 (G6/G7)** `exit(42)` -> `Err(DockerError)`; `panic!("")` -> `Err(DockerError)`. A
  library must not terminate its caller's process, least of all on a remote executor where
  the exit code is the only artifact.
- **D6 (G8)** `stop(id, delete)` returns `Ok(())` when the container is already gone.
  Deleting something absent is the requested end state, and the blueprint asserts on it.
- **D9 (3.3)** Run the `WaitUntilReady` loop on a dedicated thread so a probe may build a
  runtime even when `setup_container` was called from `#[tokio::test]`.
- **D7 (G9, optional)** `ContainerConfig::remove_on_exit(bool)`, default `true`.
- **D8 (G10, optional)** Base "is starting" on `docker inspect .State.Status`.

Minimum that fixes the test: **W1, W2, D1, D2, D3, D4, D9**. D5/D6 are independent hardening
worth the same release. W3 makes D2 uniform.

### `service_utils`

- **S1** Honour `WaitUntilReady` (run the sync probe off the reactor). Without it the new
  variant is a `docker_utils`-only variant and G5 has simply changed direction.

## 5. What the test becomes

Blueprint shape: linear, no waiting, no diagnostics scraping.

```rust
#[test]                                   // NOT #[tokio::test] -- see below
#[ignore = "requires Docker"]
fn dgraph_client_acceptance() {
    let docker = DockerUtil::with_debug().expect("Failed to get DockerUtil");

    // Blocks until the alpha accepts an Alter. If it never does, the error already carries
    // the container's exit state and log tail -- including an OOM kill, which is otherwise
    // indistinguishable from a network fault.
    let result = docker.setup_container(&dgraph_container_config());
    assert!(result.is_ok(), "{result:?}");
    let (container_id, port) = result.unwrap();
    println!("✅ Dgraph container {container_id} ready on {port}");

    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run_scenarios(port));

    // A container that dies *mid-run* is outside the setup-time diagnostics, and `--rm` reaps
    // it in seconds, so ask before tearing down. This is the one thing the crate cannot do
    // for us: nothing calls into it while the scenarios run.
    if outcome.is_err() {
        match docker.container_diagnostics(&container_id, 200) {
            Ok(d) if d.looks_oom_killed() =>
                eprintln!("container was OOM-killed -- raise test.EstimatedMemory\n{d}"),
            Ok(d)  => eprintln!("container diagnostics:\n{d}"),
            Err(e) => eprintln!("diagnostics unavailable: {e}"),
        }
    }

    let stopped = docker.stop_container(&container_id, true);
    outcome.expect("acceptance scenario failed");
    assert!(stopped.is_ok(), "{stopped:?}");
}
```

Two deliberate departures from the blueprint, both forced by Dgraph rather than by taste:

- **`#[test]` + one explicit runtime, not `#[tokio::test]`.** Dgraph is a cluster whose
  scenarios must run in a fixed order because several call `drop_all`; cargo and Bazel run
  test *functions* concurrently and neither honours `--test-threads=1` in CI, so the whole
  suite is one function. Given that, an explicit runtime is clearer than `#[tokio::test]`,
  and it sidesteps 3.3 at the test level as well. (With D9 landed, `#[tokio::test]` would
  also be safe -- the point is that the safety comes from D9, not from luck.)
- **Five lines of mid-run diagnostics stay.** The blueprint has none because postgres in a
  2 GiB container does not die mid-test; `dgraph/standalone` at ~826 MiB peak in a 4 GiB
  microVM demonstrably does.

The readiness condition moves into the spec, where the blueprint keeps it:

```rust
/// Ready means the alpha accepts an `Alter`.
///
/// Cold-start ordering for `dgraph/standalone:v25.3.8`: a read query answers at ~1s, an
/// `Alter` at ~5s, `/health` 200 at ~7s. The suite's first operation is `drop_all`, an
/// `Alter`, so any earlier signal admits a window in which the suite starts and dies on
/// `drop_all failed: RPC Error: Unknown: transport error`. Dgraph does not implement
/// `grpc.health.v1`, so the blueprint's `WaitForGrpcHealthCheck` is not available here.
///
/// Destructive by construction. Safe because the container is created fresh; note that with
/// `reuse_container(true)` this wipes a reused cluster.
fn dgraph_ready(ctx: &ProbeContext) -> Probe<(), String> {
    // Its own runtime: D9 guarantees no ambient one. See 3.3.
    let runtime = match Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(err) => return Probe::Fatal(format!("could not build a probe runtime: {err}")),
    };
    let connection_string = format!("dgraph://{CONNECT_HOST}:{}", ctx.port());

    runtime.block_on(async {
        let client = match DgraphClient::connect(&connection_string).await {
            Ok(client) => client,
            Err(err) => return classify("connect", &err),
        };
        match client.drop_all().await {
            Ok(()) => Probe::Ready(()),
            Err(err) => classify("drop_all", &err),
        }
    })
}

/// Only readiness-shaped failures are retried: "cluster not ready", and transport failures,
/// which is how tonic reports a connection the alpha closed while still starting. Everything
/// else is reported at once rather than retried into a timeout that buries the cause.
fn classify(probe: &str, err: &DgraphError) -> Probe<(), String> {
    let detail = format!("{probe} -> {err} (kind={:?})", err.kind());
    if err.is_cluster_not_ready() || err.is_transport() {
        Probe::Retry(detail)
    } else {
        Probe::Fatal(format!("{detail} NOT RETRYABLE"))
    }
}
```

### Where the spec lives

The blueprint puts it in a crate (`container_specs_postgres`), not in the test. That is the
right endpoint, and it is the *only* option for sharing: Bazel cannot reach helper files under
`tests/` from another target ([rust/README_RUST.md](rust/README_RUST.md) §6), so a `tests/` module cannot be reused.

Day one there is one consumer, so keep `dgraph_container_config()` + `dgraph_ready` in the test
file. Extract to `rust/dgraph-test-fixtures` (workspace member, `BUILD.bazel`, dev-dep of
`dgraph-client`) the moment a second crate needs a dgraph container -- not to
`dgraph-client/src/utils_tests/`, which would drag `docker_utils` out of `[dev-dependencies]`
and into the shipped library.

### What disappears, and what provides it

| Deleted from the test | Now provided by |
|---|---|
| `wait_until_ready_async` call, `probe_once`, `ProbeFailure` | `WaitStrategy::WaitUntilReady` (W1/D1) |
| liveness check per attempt, `docker` threaded through `run_scenarios`/`classify` | D2, inside the crate, for all strategies |
| `dump_diagnostics` at setup time | D3, attached to the setup error |
| `step!`, `START`, `elapsed_secs` | `wait_until_ready`'s own attempt log (it already collapses repeats) |
| `READY_TIMEOUT` / `READY_RETRY_DELAY` plumbing | two fields of the strategy |
| the 30-line comment explaining `NoWait` | the config now states the readiness condition |

~180 lines of fixture become a ~25-line probe and a ~20-line test body.

### What stays

- **One test function** -- ordering, as above.
- **Five lines of mid-run diagnostics** -- as above.
- **`test.EstimatedMemory: "4Gi"`** in [rust/dgraph-client/tests/BUILD.bazel](rust/dgraph-client/tests/BUILD.bazel). Dgraph peaks at
  ~826 MiB and the 2 GiB executor default also covers the guest kernel, dockerd, containerd
  and the test binary. That is what the OOM was.
- **`host_network(true)`** -- removes NAT and the Ubuntu 24.04 nftables bridge problem.

## 6. Landing it here

```bash
# 1. bump docker_utils in the ROOT Cargo.toml only (currently `docker_utils = "0.3"`, line 89)
./scripts/vendor.sh                                        # 2. the only supported way
cargo check -p dgraph-client --lib --bins --tests          # 3. cargo, incl. test code
cargo test  -p dgraph-client --test dgraph_container_test -- --include-ignored --nocapture
bazel build //rust/dgraph-client/...                       # 4. the one that decides
bazel test  //rust/dgraph-client/tests:acceptance_tests
```

Two repo-specific traps:

- **`wait_utils` has zero entries in `//third_party/crates:defs.bzl`** -- it is only a
  transitive dependency, so `all_crate_deps()` cannot resolve it. `Probe`, `ProbeContext` and
  `ProbeFn` must be imported through `docker_utils`' `pub use wait_utils::*` re-export.
  `use wait_utils::...` compiles under cargo and fails under Bazel. The current test already
  documents this at its import; keep that note.
- **`scripts/vendor.sh` `rm -rf`s the tree first**, so a mid-run failure leaves it empty until
  re-run. It also hard-fails if `openssl-src`/`pq-src` moved.
