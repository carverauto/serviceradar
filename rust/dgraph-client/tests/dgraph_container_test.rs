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

use std::process::Command;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use docker_utils::{ContainerConfig, DockerUtil, WaitStrategy};

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

const TEST_SCHEMA: &str = "name: string @index(exact) .";

/// No container-side wait. Readiness is decided by [`wait_until_serving`] instead.
///
/// Every strategy `wait_utils` offers is unusable for Dgraph, which is a property of the
/// strategies, not a preference:
///
/// - `WaitForHttpHealthCheck` runs `curl <url>` and accepts **process exit 0**, never
///   checking the status code. `curl` exits 0 for a 503, and a starting alpha answers
///   `/health` with 503 `Please retry again, server is not ready to accept requests`.
///   Measured against `dgraph/standalone:v25.3.8`, this gate opens **0.5s** after
///   `docker run` -- about ten seconds before the alpha can serve anything. It reports
///   "port is listening", which is not what the suite needs to know.
/// - `WaitUntilConsoleOutputContains` searches `docker logs`' **stdout**. Dgraph writes
///   glog to **stderr**, so `Server is ready: OK` never appears on the stream being
///   searched and the strategy can only ever time out.
/// - `WaitForGrpcHealthCheck` requires `grpc.health.v1`, which Dgraph does not implement.
///
/// Choosing `NoWait` also removes a failure mode: `docker_utils` panics rather than
/// returning an error when a wait strategy times out, which aborts the process and takes
/// the container diagnostics down with it.
fn wait_strategy() -> WaitStrategy {
    WaitStrategy::NoWait
}

/// Run on the host network instead of publishing ports.
/// Host networking removes NAT from the picture: Dgraph binds 9080/8080 directly in the
/// VM's network namespace, so no iptables rule has to exist for the test to reach it.
fn dgraph_container_config() -> ContainerConfig<'static> {
    ContainerConfig::builder()
        .name(CONTAINER_NAME)
        .image(IMAGE)
        .tag(TAG)
        .url(BIND_URL)
        // The gRPC port is the primary connection; HTTP accompanies it. Under host
        // networking nothing is published -- these are the ports Dgraph binds directly,
        // and `setup_container` still hands back `connection_port`, so the client's
        // `dgraph://127.0.0.1:9080` is correct in both modes.
        .connection_port(GRPC_PORT)
        .additional_ports(&[HTTP_PORT])
        .reuse_container(true)
        .keep_configuration(true)
        .host_network(true)
        .wait_strategy(wait_strategy())
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
            dump_diagnostics(&format!("{CONTAINER_NAME}-{GRPC_PORT}"));
            panic!("failed to start dgraph/standalone container: {err}");
        }
    };

    step!("container '{container_id}' up, connection port {port}");

    // One runtime for the whole run. The client is async because tonic is; docker_utils is
    // not, so nothing outside these scenarios needs a runtime.
    let runtime = tokio::runtime::Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run_scenarios(&container_id, port));

    // Dump the container's own account of events *before* tearing it down. Once
    // `stop_container` deletes it the logs are unrecoverable, and on a remote executor
    // there is no second chance to look.
    if let Err(err) = &outcome {
        step!("FAILED: {err}");
        dump_diagnostics(&container_id);
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

/// Print everything about the container that helps explain a failure after the fact.
///
/// Deliberately best effort: diagnostics must never mask the failure being diagnosed, so a
/// broken `docker` here is reported and stepped over rather than propagated.
fn dump_diagnostics(container_id: &str) {
    step!("--- diagnostics for '{container_id}' ---");

    // `docker inspect` first: if the alpha died and was restarted, that alone explains a
    // mid-run `transport error`, and the log tail below would not obviously show it.
    run_diagnostic(
        "docker inspect",
        &[
            "inspect",
            "-f",
            "status={{.State.Status}} running={{.State.Running}} restarts={{.RestartCount}} \
             oom={{.State.OOMKilled}} exit={{.State.ExitCode}} started={{.State.StartedAt}}",
            container_id,
        ],
    );

    // Dgraph writes glog to stderr, so both streams have to be printed. This is the same
    // detail that makes `WaitUntilConsoleOutputContains` unusable here.
    run_diagnostic("docker logs", &["logs", "--tail", "200", container_id]);
}

fn run_diagnostic(label: &str, args: &[&str]) {
    match Command::new("docker").args(args).output() {
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            step!("{label} (exit {}):", out.status);
            if !stdout.trim().is_empty() {
                println!("{}", stdout.trim_end());
            }
            if !stderr.trim().is_empty() {
                println!("{}", stderr.trim_end());
            }
        }
        Err(err) => step!("{label} unavailable: {err}"),
    }
}

/// Every scenario, in order. Ordering matters: several call `drop_all`.
async fn run_scenarios(container_id: &str, port: u16) -> Result<(), String> {
    // Plaintext: the standalone image serves gRPC without TLS.
    let connection_string = format!("dgraph://{CONNECT_HOST}:{port}");
    let client = wait_until_serving(container_id, &connection_string).await?;

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

/// Wait until the cluster will serve the suite's *first real operation*, then hand back a
/// client that is known to work.
///
/// The gate is three probes because each one goes green at a different moment, and the
/// earlier ones do not imply the later ones:
///
/// 1. `connect()` -- its readiness probe is `CheckVersion`. While the alpha is starting
///    this returns "server is not ready", which the client classifies as
///    [`DgraphError::is_cluster_not_ready`]. Branching on the typed variant rather than on
///    message text is the point of the crate's error surface.
/// 2. a read query -- an alpha answers `CheckVersion` before it can serve queries.
/// 3. an `Alter` (`drop_all`) -- and it serves queries before it accepts an `Alter`.
///
/// Probe 3 is the one that matters and the one that was missing. Gating on anything weaker
/// leaves a window in which the suite starts, runs its first scenario, and dies on
/// `drop_all failed: RPC Error: Unknown: transport error`. Running the real operation as
/// the gate removes the guesswork entirely: there is no proxy signal left to be wrong
/// about. It costs nothing, because the first scenario begins by dropping everything
/// anyway.
///
/// Retries are confined to readiness-shaped failures -- "cluster not ready" and transport
/// failures, the latter being how tonic reports a connection that the alpha closed while
/// still starting. Every other error aborts immediately rather than being retried into a
/// timeout that buries the real cause.
async fn wait_until_serving(
    container_id: &str,
    connection_string: &str,
) -> Result<DgraphClient, String> {
    let deadline = Instant::now() + READY_TIMEOUT;
    let mut attempt = 0u32;
    // Uninitialised on purpose: the only path that reaches the deadline check is the
    // retry arm, which always assigns first. A placeholder here could be reported as the
    // cause of a timeout without ever having been a real error.
    let mut last_error;
    // A starting alpha repeats the same refusal for as long as it takes, and printing it
    // a hundred times buries the one line that differs -- which is always the interesting
    // one. Collapse runs instead, so the log reads as a sequence of state changes.
    let mut repeated = Repeats::default();

    loop {
        attempt += 1;
        match probe_once(connection_string).await {
            Ok(client) => {
                repeated.flush();
                step!("cluster serving after {attempt} attempt(s)");
                return Ok(client);
            }
            Err(Readiness::Fatal(err)) => {
                repeated.flush();
                step!("attempt {attempt}: {err}");
                return Err(err);
            }
            Err(Readiness::Retry(err)) => {
                // A dead container produces exactly the same "tcp connect error" as one
                // that has not finished booting. Without this check the loop would retry a
                // corpse for the full budget and report a timeout, when what happened was
                // an OOM kill seconds in. Check promptly, too: `docker run --rm` reaps the
                // container, and once it is gone so is the exit code that explains it.
                if container_running(container_id) == Some(false) {
                    repeated.flush();
                    return Err(format!(
                        "container '{container_id}' stopped while waiting for it to serve \
                         (last error: {err})"
                    ));
                }

                repeated.observe(attempt, &err);
                last_error = err;
            }
        }

        if Instant::now() >= deadline {
            repeated.flush();
            return Err(format!(
                "dgraph never became ready within {}s ({attempt} attempts). Last error: {last_error}",
                READY_TIMEOUT.as_secs()
            ));
        }

        tokio::time::sleep(READY_RETRY_DELAY).await;
    }
}

/// Whether the container is still running.
///
/// `None` means docker could not be asked and the caller should not conclude anything;
/// `Some(false)` covers both "exited" and "no longer exists", since `--rm` deletes a
/// container the moment it dies and both mean the same thing to a client trying to reach
/// it.
fn container_running(container_id: &str) -> Option<bool> {
    let out = Command::new("docker")
        .args(["inspect", "-f", "{{.State.Running}}", container_id])
        .output()
        .ok()?;

    if !out.status.success() {
        return Some(false);
    }

    Some(String::from_utf8_lossy(&out.stdout).trim() == "true")
}

/// Collapses consecutive identical retry messages into one line plus a count.
#[derive(Default)]
struct Repeats {
    current: String,
    count: u32,
}

impl Repeats {
    /// Log `message` if it differs from the run in progress, otherwise just count it.
    fn observe(&mut self, attempt: u32, message: &str) {
        if message == self.current {
            self.count += 1;
            return;
        }

        self.flush();
        step!("attempt {attempt}: {message}");
        self.current = message.to_string();
        self.count = 0;
    }

    /// Report any suppressed repeats before the log moves on to something else.
    fn flush(&mut self) {
        if self.count > 0 {
            step!("  (same for {} further attempt(s))", self.count);
        }
        self.current.clear();
        self.count = 0;
    }
}

/// Outcome of one readiness attempt: worth another try, or hopeless.
enum Readiness {
    Retry(String),
    Fatal(String),
}

/// Classify a client error into [`Readiness`], carrying a message for the caller to log.
///
/// The message includes the typed `kind`, because the `Display` text alone does not say
/// which variant produced it, and the variant is what determines whether it is retried.
fn classify(probe: &str, err: &dgraph_client::DgraphError) -> Readiness {
    let retryable = err.is_cluster_not_ready() || err.is_transport();
    let detail = format!("{probe} -> {err} (kind={:?})", err.kind());

    if retryable {
        Readiness::Retry(detail)
    } else {
        Readiness::Fatal(format!("{detail} NOT RETRYABLE, giving up"))
    }
}

async fn probe_once(connection_string: &str) -> Result<DgraphClient, Readiness> {
    let client = DgraphClient::connect(connection_string)
        .await
        .map_err(|err| classify("connect", &err))?;

    let mut txn = client.new_read_only_txn();
    txn.query("{ warmup(func: has(_predicate_)) { uid } }")
        .await
        .map_err(|err| classify("read query", &err))?;

    // The suite's first operation, used as its own readiness signal.
    client
        .drop_all()
        .await
        .map_err(|err| classify("drop_all", &err))?;

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
