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
//!
//! # The container is left running
//!
//! Teardown deliberately does not stop the container. With `reuse_container(true)` the next
//! run finds it already up and skips the cold start, and `docker_utils` applies the wait
//! strategy on the reuse path as well -- so the readiness gate still holds, and because that
//! gate *is* `drop_all`, a reused cluster is empty before the first scenario runs. The suite
//! therefore starts from the same state whether the container is fresh or warm.
//!
//! Stopping it would preserve nothing in any case: the container carries `--rm`, so
//! `docker stop` removes it exactly as `docker rm -f` does. The real choice is between a warm
//! container and a cold start, not between stopping and deleting.
//!
//! Remove it by hand when it is no longer wanted:
//!
//! ```bash
//! docker rm -f dgraph-standalone-9080
//! ```

use tokio::runtime::{Builder, Runtime};

// `Probe`, `ProbeContext` and `WaitStrategy` belong to `wait_utils`, but are reached through
// `docker_utils`' re-export on purpose: `wait_utils` is only a transitive dependency here,
// so it has no entry in `//third_party/crates:defs.bzl` and `all_crate_deps()` cannot
// resolve it. `use wait_utils::...` compiles under cargo and fails under Bazel.
use docker_utils::{ContainerConfig, DockerUtil, Probe, ProbeContext, WaitStrategy};

use dgraph_client::{DgraphClient, DgraphError, Mutation};

/// Container name. `docker_utils` appends the connection port, so the running container is
/// `dgraph-standalone-9080`.
const CONTAINER_NAME: &str = "dgraph-standalone";
const IMAGE: &str = "dgraph/standalone";
const TAG: &str = "v25.3.8";

/// Address the test connects to, and the address `docker_utils` hands the readiness probe as
/// [`ProbeContext::host`].
///
/// This is a connection target, not a bind address. `ContainerConfig::url` never reaches
/// `docker run` -- it is forwarded to the probe and nowhere else -- so a wildcard `0.0.0.0`
/// here would only produce a probe that cannot connect. Under host networking Dgraph binds
/// directly in this network namespace, so loopback reaches it without any published port.
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
const READY_TIMEOUT_SECS: u64 = 120;
const READY_RETRY_DELAY_MS: u64 = 500;

/// Lines of container log to capture when a scenario fails.
///
/// Dgraph's startup chatter alone is long, so a short tail would cut off precisely the
/// alpha's account of what went wrong.
const DIAGNOSTIC_LOG_LINES: usize = 200;

const TEST_SCHEMA: &str = "name: string @index(exact) .";

/// Ready means the alpha accepts an `Alter`.
///
/// Each signal goes green at a different moment, and the earlier ones do not imply the later
/// ones: `connect()`'s `CheckVersion` probe answers first, a read query some seconds later,
/// and an `Alter` later still. The suite's first operation is `drop_all`, an `Alter`, so
/// gating on anything weaker leaves a window in which the suite starts, runs its first
/// scenario, and dies on `drop_all failed: RPC Error: Unknown: transport error`.
///
/// Running the real operation as the gate removes the guesswork entirely -- there is no proxy
/// signal left to be wrong about -- and it costs nothing, because the first scenario begins by
/// dropping everything anyway. Dgraph does not implement `grpc.health.v1`, so
/// `WaitForGrpcHealthCheck` is not an option here regardless of which driver applies it.
///
/// Destructive by construction. Safe here because a reused container is one this suite
/// created and is about to wipe anyway.
fn dgraph_ready(ctx: &ProbeContext) -> Probe<(), String> {
    // A `ProbeFn` is synchronous by contract, so the async client is flattened here rather
    // than in the crate: only the caller knows whether a runtime exists. Building one is safe
    // because `docker_utils` runs the probe on a thread of its own precisely so that there is
    // never an ambient runtime, even when `setup_container` is called from `#[tokio::test]`.
    let runtime = match Builder::new_current_thread().enable_all().build() {
        Ok(runtime) => runtime,
        Err(err) => return Probe::Fatal(format!("could not build a probe runtime: {err}")),
    };

    let connection_string = connection_string(ctx.host(), ctx.port());

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

/// Decide whether a failed readiness attempt is worth another one.
///
/// Retries are confined to readiness-shaped failures -- "cluster not ready" and transport
/// failures, the latter being how tonic reports a connection that the alpha closed while
/// still starting. Every other error is reported at once rather than retried into a timeout
/// that buries the real cause.
///
/// The typed `kind` accompanies the message because `Display` alone does not say which
/// variant produced it, and the variant is what decides whether it is retried. Branching on
/// the typed variant rather than on message text is the point of the crate's error surface.
fn classify(probe: &str, err: &DgraphError) -> Probe<(), String> {
    let detail = format!("{probe} -> {err} (kind={:?})", err.kind());

    if err.is_cluster_not_ready() || err.is_transport() {
        Probe::Retry(detail)
    } else {
        Probe::Fatal(format!("{detail} NOT RETRYABLE"))
    }
}

/// Plaintext: the standalone image serves gRPC without TLS.
fn connection_string(host: &str, port: u16) -> String {
    format!("dgraph://{host}:{port}")
}

/// Run on the host network instead of publishing ports.
///
/// Host networking removes NAT from the picture: Dgraph binds 9080/8080 directly in the
/// VM's network namespace, so no iptables rule has to exist for the test to reach it.
fn dgraph_container_config() -> ContainerConfig<'static> {
    ContainerConfig::builder()
        .name(CONTAINER_NAME)
        .image(IMAGE)
        .tag(TAG)
        .url(CONNECT_HOST)
        // The gRPC port is the primary connection; HTTP is exposed but not gated on.
        .connection_port(GRPC_PORT)
        .additional_ports(&[HTTP_PORT])
        .reuse_container(true)
        .keep_configuration(true)
        .host_network(true)
        // Readiness is part of the configuration, so it holds on every path
        // `setup_container` can take -- including handing back a reused container, which is
        // where a stale one from a killed run would otherwise slip through on a recycled
        // runner.
        .wait_strategy(WaitStrategy::WaitUntilReady {
            probe: dgraph_ready,
            timeout_secs: READY_TIMEOUT_SECS,
            retry_delay_ms: READY_RETRY_DELAY_MS,
        })
        .build()
}

/// The single acceptance test.
///
/// Starts or reuses the container, then runs every scenario in order. The container is left
/// running afterwards, pass or fail -- see the module docs.
#[test]
#[ignore = "requires Docker"]
fn dgraph_client_acceptance() {
    let docker = DockerUtil::with_debug().expect("failed to construct DockerUtil");

    // Blocks until the alpha accepts an `Alter`. If it never does, the error already carries
    // the container's exit state and log tail, including an OOM kill -- which is otherwise
    // indistinguishable from a network fault, because the server never got to explain itself.
    let started = docker.setup_container(&dgraph_container_config());
    assert!(started.is_ok(), "{started:?}");
    let (container_id, port) = started.unwrap();
    println!("✅ container '{container_id}' ready on {CONNECT_HOST}:{port}");

    // One runtime for the whole run. The client is async because tonic is; docker_utils is
    // not, so nothing outside these scenarios needs a runtime.
    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run_scenarios(port));

    // A container that dies *mid-run* is the one failure `docker_utils` cannot explain for
    // us, because nothing calls into it while the scenarios run. `--rm` reaps the container
    // within seconds of the exit that explains it, so ask while there is still something to
    // ask -- a container that died is gone, whether or not this test would have stopped it.
    if let Err(err) = &outcome {
        eprintln!("FAILED: {err}");
        match docker.container_diagnostics(&container_id, DIAGNOSTIC_LOG_LINES) {
            Ok(diagnostics) if diagnostics.looks_oom_killed() => eprintln!(
                "container was OOM-killed -- raise test.EstimatedMemory in BUILD.bazel\n{diagnostics}"
            ),
            Ok(diagnostics) => eprintln!("container diagnostics:\n{diagnostics}"),
            Err(err) => eprintln!("diagnostics unavailable: {err}"),
        }
    }

    // No teardown by design: the container stays up so the next run reuses it. See the module
    // docs for why leaving it running is what makes the second run both faster and clean.
    outcome.expect("acceptance scenario failed");
    println!("✅ all scenarios passed; container '{container_id}' left running for reuse");
}

/// Every scenario, in order. Ordering matters: several call `drop_all`.
async fn run_scenarios(port: u16) -> Result<(), String> {
    // No retry loop: `setup_container` returned, so the cluster has already served an `Alter`.
    let client = DgraphClient::connect(&connection_string(CONNECT_HOST, port))
        .await
        .map_err(|err| format!("connect failed: {err}"))?;

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
    println!("scenario {name}");
    body().map_err(|err| format!("{name}: {err}"))
}

async fn scenario_async(
    name: &str,
    body: impl Future<Output = Result<(), String>>,
) -> Result<(), String> {
    println!("scenario {name}");
    body.await.map_err(|err| format!("{name}: {err}"))
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
