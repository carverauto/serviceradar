/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Acceptance tests against a real Dgraph.
//!
//! Starts a `dgraph/standalone` container with `docker_utils` and tests the client.
//!
//! ```bash
//! cargo test -p dgraph-client -- --ignored
//! ```
//!
//! # Why this is one test function
//!
//! Every scenario shares one container, and several call `drop_all`, which wipes the
//! cluster. Both cargo and Bazel run test *functions* concurrently, and neither honours
//! `--test-threads=1` in CI regardless of how the target is tagged, so separate `#[test]`
//! functions would race: one scenario's `drop_all` would delete another's data mid-run.
//!
//! Sequencing the scenarios inside a single test is therefore not a style choice, it is
//! the only way to make ordering deterministic on any runner. Each scenario is a plain
//! async fn returning `Result`, so a failure still reports which one broke.
//!
//! Because there is exactly one test, it is a plain `#[test]` that drives the async client
//! through one explicit runtime, rather than `#[tokio::test]`. `docker_utils` is itself
//! synchronous, so only the client interaction needs a runtime at all.

use std::sync::OnceLock;
use std::time::{Duration, Instant};

// `Probe` and `wait_until_ready_async` belong to `wait_utils`, but are reached through
// `docker_utils`' re-export on purpose: `wait_utils` is only a transitive dependency here,
// so it has no entry in `//third_party/crates:defs.bzl` and `all_crate_deps()` cannot
// resolve it. `use wait_utils::...` compiles under cargo and fails under Bazel.
use docker_utils::{ContainerConfig, DockerUtil, Probe, WaitStrategy, wait_until_ready_async};

use dgraph_client::{DgraphClient, Mutation};

/// Wall clock for the whole run, so every log line carries an elapsed time.
static START: OnceLock<Instant> = OnceLock::new();

fn elapsed_secs() -> f64 {
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// Log a step with its elapsed time.
///
/// This suite runs on a remote executor inside a microVM. When it fails there, this output
/// is the only evidence available -- there is no shell to poke at the container afterwards,
/// because the runner is gone. Logging every step is therefore not noise, it is the whole
/// debugging surface.
macro_rules! step {
    ($($arg:tt)*) => {
        println!("[dgraph-acceptance] [{:>6.1}s] {}", elapsed_secs(), format_args!($($arg)*))
    };
}

/// Container name. `docker_utils` appends the connection port, so the running container is
/// `dgraph-standalone-9080`.
const CONTAINER_NAME: &str = "dgraph-standalone";
const IMAGE: &str = "dgraph/standalone";
const TAG: &str = "v25.3.8";
/// Address the container binds. `0.0.0.0` means "every interface".
const BIND_URL: &str = "0.0.0.0";

/// Address the test connects to.
///
/// Deliberately separate from [`BIND_URL`]: a wildcard bind address is not a meaningful
/// connection target. Under host networking Dgraph binds directly in this network
/// namespace, so loopback reaches it without any published port.
const CONNECT_HOST: &str = "127.0.0.1";

/// gRPC port. This is the one the client talks to.
const GRPC_PORT: u16 = 9080;
/// HTTP admin port. Declared so the container exposes the same surface it would in
/// production; readiness is decided over gRPC, not here.
const HTTP_PORT: u16 = 8080;

/// How long the cluster gets to become able to serve the suite's first operation.
///
/// A deadline rather than an attempt count: attempts times delay silently shrinks the real
/// wait whenever an attempt itself is slow, which is exactly what happens on a loaded
/// executor -- the case the budget exists for.
const READY_TIMEOUT: Duration = Duration::from_secs(120);
const READY_RETRY_DELAY: Duration = Duration::from_millis(500);

/// Lines of container log to capture when a scenario fails.
///
/// Dgraph's startup chatter alone is long, so a short tail would cut off precisely the
/// alpha's account of what went wrong.
const DIAGNOSTIC_LOG_LINES: usize = 200;

const TEST_SCHEMA: &str = "name: string @index(exact) .";

/// Run on the host network instead of publishing ports.
/// Host networking removes NAT from the picture: Dgraph binds 9080/8080 directly in the
/// VM's network namespace, so no iptables rule has to exist for the test to reach it.
fn dgraph_container_config() -> ContainerConfig<'static> {
    ContainerConfig::builder()
        .name(CONTAINER_NAME)
        .image(IMAGE)
        .tag(TAG)
        .url(BIND_URL)
        // The gRPC port is the primary connection; HTTP provides health check.
        .connection_port(GRPC_PORT)
        .additional_ports(&[HTTP_PORT])
        .reuse_container(true)
        .keep_configuration(true)
        .host_network(true)
        // No container-side wait: readiness is decided by the `wait_until_ready_async` loop
        // in `run_scenarios`, which gates on the suite's first real operation.
        //
        // Not a workaround. As of `docker_utils` 0.3.2 the built-in strategies are sound,
        // they just answer a different question than this suite has to ask:
        //
        // - `WaitForHttpHealthCheck` gates on `/health` returning 200, which is a real
        //   signal -- but the alpha serves reads seconds before it accepts an `Alter`, and
        //   `Alter` is what the first scenario does.
        // - `WaitUntilConsoleOutputContains("Server is ready: OK", n)` would work and would
        //   cut most of the retry spinning. It still does not prove an `Alter` is accepted,
        //   and it cannot notice the container being OOM-killed afterwards.
        // - `WaitForGrpcHealthCheck` needs `grpc.health.v1`, which Dgraph does not
        //   implement.
        //
        // `wait_until_ready_async` cannot be a `WaitStrategy` variant, which is why this is
        // `NoWait` rather than a strategy naming the probe: the probe captures state, and a
        // `Box<dyn Fn>` would strip `Eq`/`Ord`/`Hash`/`Debug` from `WaitStrategy` and hence
        // from `ContainerConfig`, which merely holds one. It is also async, while the
        // strategy is applied on a sync path, and it returns the connected client, which an
        // enum variant has nowhere to put.
        .wait_strategy(WaitStrategy::NoWait)
        .build()
}

/// The single acceptance test.
///
/// Starts the container once, runs every scenario in order, and stops the container even
/// when a scenario fails.
#[test]
#[ignore = "requires Docker"]
fn dgraph_client_acceptance() {
    START.get_or_init(Instant::now);
    step!("start: image {IMAGE}:{TAG}, host networking, gRPC {GRPC_PORT}, HTTP {HTTP_PORT}");

    let docker = DockerUtil::with_debug().expect("failed to construct DockerUtil");

    let config = dgraph_container_config();
    step!("setup_container: pulling if absent and starting");
    let (container_id, port) = match docker.setup_container(&config) {
        Ok(started) => started,
        Err(err) => {
            // A container that failed to start still has logs, and they are the only
            // explanation available on a remote runner. Print them before unwinding.
            step!("setup_container failed: {err}");
            dump_diagnostics(docker, &format!("{CONTAINER_NAME}-{GRPC_PORT}"));
            panic!("failed to start dgraph/standalone container: {err}");
        }
    };

    step!("container '{container_id}' up, connection port {port}");

    // One runtime for the whole run. The client is async because tonic is; docker_utils is
    // not, so nothing outside these scenarios needs a runtime.
    let runtime = tokio::runtime::Runtime::new().expect("failed to build a tokio runtime");
    // `DockerUtil` is `Copy`, so the readiness loop can hold one without borrowing.
    let outcome = runtime.block_on(run_scenarios(docker, &container_id, port));

    // Dump the container's own account of events *before* tearing it down. Once
    // `stop_container` deletes it the logs are unrecoverable, and on a remote executor
    // there is no second chance to look.
    if let Err(err) = &outcome {
        step!("FAILED: {err}");
        dump_diagnostics(docker, &container_id);
    }

    // Stop before asserting, so a failing scenario still tears the container down.
    let delete_container = true;
    let stopped = docker.stop_container(&container_id, delete_container);

    if let Err(err) = outcome {
        panic!("acceptance scenario failed: {err}");
    }
    step!("all scenarios passed");
    stopped.expect("failed to stop dgraph container");
}

/// Print the container's own account of a failure.
///
/// Deliberately best effort: diagnostics must never mask the failure being diagnosed, so a
/// broken `docker` here is reported and stepped over rather than propagated.
fn dump_diagnostics(docker: DockerUtil, container_id: &str) {
    match docker.container_diagnostics(container_id, DIAGNOSTIC_LOG_LINES) {
        // Called out separately because it is the failure this suite actually hit, and the
        // raw dump reads like a network fault without it: an OOM-killed alpha reaches the
        // client as a bare transport error, since the server never got to explain itself.
        Ok(diagnostics) if diagnostics.looks_oom_killed() => step!(
            "container was OOM-killed -- raise test.EstimatedMemory in BUILD.bazel\n{diagnostics}"
        ),
        Ok(diagnostics) => step!("container diagnostics:\n{diagnostics}"),
        Err(err) => step!("diagnostics unavailable: {err}"),
    }
}

/// Every scenario, in order. Ordering matters: several call `drop_all`.
async fn run_scenarios(docker: DockerUtil, container_id: &str, port: u16) -> Result<(), String> {
    // Plaintext: the standalone image serves gRPC without TLS.
    let connection_string = format!("dgraph://{CONNECT_HOST}:{port}");

    // Wait until the cluster serves the suite's *first real operation*, then keep the client
    // the successful attempt built.
    //
    // `dbg = true`: the retry log is the whole debugging surface on a remote executor, and
    // `wait_until_ready_async` collapses consecutive identical refusals, so a starting alpha
    // does not bury the one line that differs.
    let client = wait_until_ready_async(true, READY_TIMEOUT, READY_RETRY_DELAY, || async {
        match probe_once(&connection_string).await {
            Ok(client) => Probe::Ready(client),
            Err((probe, err)) => classify(docker, container_id, probe, &err),
        }
    })
    .await
    .map_err(|err| err.to_string())?;

    // Named so a failure names the scenario, not just a line number.
    scenario("connects_and_probes", || connects_and_probes(&client))?;
    scenario_async(
        "sets_schema_and_round_trips_a_mutation",
        sets_schema_and_round_trips_a_mutation(&client),
    )
    .await?;
    scenario_async(
        "discard_rolls_back_a_mutation",
        discard_rolls_back_a_mutation(&client),
    )
    .await?;
    scenario_async(
        "best_effort_read_only_transaction_queries",
        best_effort_read_only_transaction_queries(&client),
    )
    .await?;
    scenario_async(
        "upsert_applies_query_and_mutation_together",
        upsert_applies_query_and_mutation_together(&client),
    )
    .await?;
    scenario_async("allocates_uid_ranges", allocates_uid_ranges(&client)).await?;
    scenario_async(
        "run_dql_without_a_transaction",
        run_dql_without_a_transaction(&client),
    )
    .await?;

    Ok(())
}

fn scenario(name: &str, body: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
    step!("scenario {name}");
    body().map_err(|err| format!("{name}: {err}"))
}

async fn scenario_async(
    name: &str,
    body: impl Future<Output = Result<(), String>>,
) -> Result<(), String> {
    step!("scenario {name}");
    body.await.map_err(|err| format!("{name}: {err}"))
}

/// Decide whether a failed readiness probe is worth another attempt.
///
/// Retries are confined to readiness-shaped failures -- "cluster not ready" and transport
/// failures, the latter being how tonic reports a connection that the alpha closed while
/// still starting. Every other error is reported at once rather than retried into a timeout
/// that buries the real cause.
fn classify(
    docker: DockerUtil,
    container_id: &str,
    probe: &str,
    err: &dgraph_client::DgraphError,
) -> Probe<DgraphClient, String> {
    // The typed `kind` accompanies the message because `Display` alone does not say which
    // variant produced it, and the variant is what decides whether it is retried.
    let detail = format!("{probe} -> {err} (kind={:?})", err.kind());

    if !(err.is_cluster_not_ready() || err.is_transport()) {
        return Probe::Fatal(format!("{detail} NOT RETRYABLE"));
    }

    // A dead container produces exactly the same "tcp connect error" as one that has not
    // finished booting. Without this check the loop would retry a corpse for the full budget
    // and report a timeout, when what happened was an OOM kill seconds in. Check promptly,
    // too: `docker run --rm` reaps the container, and once it is gone so is the exit code
    // that explains it.
    //
    // Only `Ok(false)` aborts. An `Err` means docker itself did not answer, which is no
    // evidence the container died -- treating it as death would let a transient docker
    // hiccup fail an otherwise healthy run.
    if matches!(
        docker.check_if_container_is_running(container_id),
        Ok(false)
    ) {
        return Probe::Fatal(format!("container '{container_id}' stopped ({detail})"));
    }

    Probe::Retry(detail)
}

/// Which probe failed, and how. The name is carried because the three probes go green at
/// different moments, so knowing which one refused says how far along the alpha is.
type ProbeFailure = (&'static str, dgraph_client::DgraphError);

/// One readiness attempt: prove the cluster serves the suite's *first real operation*, and
/// return the client that proved it.
///
/// Three probes, because each goes green at a different moment and the earlier ones do not
/// imply the later ones:
///
/// 1. `connect()` -- its readiness probe is `CheckVersion`. While the alpha is starting this
///    returns "server is not ready", which the client classifies as
///    [`DgraphError::is_cluster_not_ready`]. Branching on the typed variant rather than on
///    message text is the point of the crate's error surface.
/// 2. a read query -- an alpha answers `CheckVersion` before it can serve queries.
/// 3. an `Alter` (`drop_all`) -- and it serves queries before it accepts an `Alter`.
///
/// Probe 3 is the one that matters and the one that was missing. Gating on anything weaker
/// leaves a window in which the suite starts, runs its first scenario, and dies on
/// `drop_all failed: RPC Error: Unknown: transport error`. Running the real operation as the
/// gate removes the guesswork entirely: there is no proxy signal left to be wrong about. It
/// costs nothing, because the first scenario begins by dropping everything anyway.
async fn probe_once(connection_string: &str) -> Result<DgraphClient, ProbeFailure> {
    let client = DgraphClient::connect(connection_string)
        .await
        .map_err(|err| ("connect", err))?;

    let mut txn = client.new_read_only_txn();
    txn.query("{ warmup(func: has(_predicate_)) { uid } }")
        .await
        .map_err(|err| ("read query", err))?;

    // The suite's first operation, used as its own readiness signal.
    client.drop_all().await.map_err(|err| ("drop_all", err))?;

    Ok(client)
}

/// Reset the cluster and install the test schema.
async fn reset_cluster(client: &DgraphClient) -> Result<(), String> {
    client
        .drop_all()
        .await
        .map_err(|err| format!("drop_all failed: {err}"))?;
    client
        .set_schema(TEST_SCHEMA)
        .await
        .map_err(|err| format!("set_schema failed: {err}"))
}

fn connects_and_probes(client: &DgraphClient) -> Result<(), String> {
    // connect() already ran the readiness probe; reaching here means it succeeded.
    if client.endpoint_count() != 1 {
        return Err(format!(
            "expected 1 endpoint, found {}",
            client.endpoint_count()
        ));
    }
    Ok(())
}

async fn sets_schema_and_round_trips_a_mutation(client: &DgraphClient) -> Result<(), String> {
    reset_cluster(client).await?;

    let mut txn = client.new_txn();
    let response = txn
        .mutate(Mutation::new().set_json(br#"{"name":"alice"}"#.to_vec()))
        .await
        .map_err(|err| format!("mutate failed: {err}"))?;

    // A mutation reports the uid it allocated for the blank node.
    if response.uids().is_empty() {
        return Err("expected an allocated uid".to_string());
    }

    txn.commit()
        .await
        .map_err(|err| format!("commit failed: {err}"))?;

    let json = query_json(client, r#"{ q(func: eq(name, "alice")) { name } }"#).await?;
    if !json.contains("alice") {
        return Err(format!("committed data not visible: {json}"));
    }

    Ok(())
}

async fn discard_rolls_back_a_mutation(client: &DgraphClient) -> Result<(), String> {
    reset_cluster(client).await?;

    let mut txn = client.new_txn();
    txn.mutate(Mutation::new().set_json(br#"{"name":"discarded"}"#.to_vec()))
        .await
        .map_err(|err| format!("mutate failed: {err}"))?;
    txn.discard()
        .await
        .map_err(|err| format!("discard failed: {err}"))?;

    let json = query_json(client, r#"{ q(func: eq(name, "discarded")) { name } }"#).await?;
    if json.contains("discarded") {
        return Err(format!("discarded mutation was visible: {json}"));
    }

    Ok(())
}

async fn best_effort_read_only_transaction_queries(client: &DgraphClient) -> Result<(), String> {
    reset_cluster(client).await?;

    let mut txn = client.new_txn();
    txn.mutate(
        Mutation::new()
            .set_json(br#"{"name":"besteffort"}"#.to_vec())
            .commit_now(),
    )
    .await
    .map_err(|err| format!("mutate failed: {err}"))?;

    // best_effort() only exists on a read-only transaction; calling it on new_txn() would
    // not compile.
    let mut read = client.new_read_only_txn().best_effort();
    if !read.is_best_effort() {
        return Err("best_effort flag was not set".to_string());
    }

    // Assert the mechanics only: the flag reaches the wire and the alpha serves the query.
    //
    // Deliberately NOT asserting that this read observes the mutation above. A best-effort
    // read asks the alpha to serve from memory at a possibly-stale timestamp instead of
    // fetching a fresh one from zero -- trading freshness for latency is the whole point of
    // the flag. Requiring it to see a just-committed write asserts the opposite of what
    // best-effort guarantees, and only passes by luck.
    let response = read
        .query(r#"{ q(func: eq(name, "besteffort")) { name } }"#)
        .await
        .map_err(|err| format!("best-effort query failed: {err}"))?;

    if response.json().is_empty() {
        return Err("best-effort query returned no payload".to_string());
    }

    // Freshness is a property of a normal read-only transaction, so check it there.
    let json = query_json(client, r#"{ q(func: eq(name, "besteffort")) { name } }"#).await?;
    if !json.contains("besteffort") {
        return Err(format!(
            "committed data not visible to a normal read: {json}"
        ));
    }

    Ok(())
}

async fn upsert_applies_query_and_mutation_together(client: &DgraphClient) -> Result<(), String> {
    client
        .drop_all()
        .await
        .map_err(|err| format!("drop_all failed: {err}"))?;
    client
        .set_schema("email: string @index(exact) .\nname: string .")
        .await
        .map_err(|err| format!("set_schema failed: {err}"))?;

    let mut txn = client.new_txn();
    txn.upsert(
        r#"{ existing(func: eq(email, "a@example.com")) { v as uid } }"#,
        [Mutation::new()
            .set_nquads(br#"uid(v) <name> "alice" ."#.to_vec())
            .cond("@if(gt(len(v), 0))")],
        true,
    )
    .await
    .map_err(|err| format!("upsert failed: {err}"))?;

    Ok(())
}

async fn allocates_uid_ranges(client: &DgraphClient) -> Result<(), String> {
    let range = client
        .allocate_uids(100)
        .await
        .map_err(|err| format!("allocate_uids failed: {err}"))?;

    if range.start() == 0 {
        return Err("expected a non-zero start".to_string());
    }
    if range.end() < range.start() {
        return Err(format!(
            "end {} precedes start {}",
            range.end(),
            range.start()
        ));
    }

    Ok(())
}

async fn run_dql_without_a_transaction(client: &DgraphClient) -> Result<(), String> {
    reset_cluster(client).await?;

    let response = client
        .run_dql(r#"{ q(func: has(name)) { name } }"#)
        .await
        .map_err(|err| format!("run_dql failed: {err}"))?;

    // An empty graph still returns a well-formed result rather than an error.
    if response.json().is_empty() {
        return Err("expected a well-formed empty result".to_string());
    }

    Ok(())
}

async fn query_json(client: &DgraphClient, query: &str) -> Result<String, String> {
    let mut read = client.new_read_only_txn();
    let response = read
        .query(query)
        .await
        .map_err(|err| format!("query failed: {err}"))?;

    Ok(String::from_utf8_lossy(response.json()).into_owned())
}
