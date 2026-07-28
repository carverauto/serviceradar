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

use std::time::Duration;

use docker_utils::{ContainerConfig, DockerUtil, WaitStrategy};

use dgraph_client::{DgraphClient, Mutation};

/// Container name. `docker_utils` appends the connection port, so the running container is
/// `dgraph-standalone-9080`.
const CONTAINER_NAME: &str = "dgraph-standalone";
const IMAGE: &str = "dgraph/standalone";
const TAG: &str = "v25.3.8";
const BIND_URL: &str = "0.0.0.0";

/// gRPC port. This is the one the client talks to.
const GRPC_PORT: u16 = 9080;
/// HTTP admin/health port, published as well so the readiness probe can use it.
const HTTP_PORT: u16 = 8080;

/// Fixed settle time after `docker run`, before the readiness loop starts probing.
///
/// A cold `dgraph/standalone` answers `/health` in ~7s and peaks around 52 MiB, so 15s is
/// comfortably past first-ready without being a meaningful share of the test budget.
/// This is deliberately a dumb sleep rather than a health check -- see [`wait_strategy`].
const STARTUP_WAIT_SECS: u64 = 15;

/// Attempts to make when the alpha answers but reports itself not ready.
///
/// HTTP `/health` turning 200 does not mean the alpha will accept gRPC yet. This is the
/// caller-side readiness loop the client deliberately does not perform for you.
const READY_ATTEMPTS: u32 = 30;
const READY_RETRY_DELAY: Duration = Duration::from_secs(2);

/// Extra settle time after [`STARTUP_WAIT_SECS`], before the first client call.
///
/// Alpha accepting a connection does not mean its gRPC surface is fully up. Connecting
/// immediately produced a genuine cold-start flake: the version probe succeeded and a
/// later query died with `transport error`.
const POST_HEALTH_SETTLE: Duration = Duration::from_secs(5);

const TEST_SCHEMA: &str = "name: string @index(exact) .";

/// Wait a fixed interval rather than probing a health endpoint.
///
/// Two strategies are unusable here:
///
/// * `WaitForGrpcHealthCheck` -- Dgraph does not implement `grpc.health.v1`, so it can
///   never succeed.
/// * `WaitForHttpHealthCheck` -- on timeout `docker_utils` calls `.expect()` internally
///   (`docker/start.rs:293`) instead of returning an error, so the process aborts inside
///   `setup_container` and the test can never report what actually went wrong. That is
///   exactly how a CI failure here surfaced as a bare 60s timeout with no container logs.
///
/// `WaitForDuration` cannot fail, which keeps control in the test. Actual readiness is
/// still enforced -- by [`connect_when_ready`], which retries the real gRPC surface and
/// is the signal that matters to a client.
fn wait_strategy() -> WaitStrategy {
    WaitStrategy::WaitForDuration(STARTUP_WAIT_SECS)
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
    let docker = DockerUtil::with_debug().expect("failed to construct DockerUtil");

    let config = dgraph_container_config();
    let (container_id, port) = docker
        .setup_container(&config)
        .expect("failed to start dgraph/standalone container");

    println!("dgraph container '{container_id}' listening on port {port}");

    // The health check is necessary but not sufficient because it returns ready too early before alpha can serve requests;
    // give alpha a moment to finish starting before the first RPC. The readiness loop below still guards the remainder,
    // so this only has to cover the common case rather than be exactly right.
    std::thread::sleep(POST_HEALTH_SETTLE);

    // One runtime for the whole run. The client is async because tonic is; docker_utils is
    // not, so nothing outside these scenarios needs a runtime.
    let runtime = tokio::runtime::Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run_scenarios(port));

    // Stop before asserting, so a failing scenario still tears the container down.
    let delete_container = true;
    let stopped = docker.stop_container(&container_id, delete_container);

    if let Err(err) = outcome {
        panic!("acceptance scenario failed: {err}");
    }
    stopped.expect("failed to stop dgraph container");
}

/// Every scenario, in order. Ordering matters: several call `drop_all`.
async fn run_scenarios(port: u16) -> Result<(), String> {
    // Plaintext: the standalone image serves gRPC without TLS.
    let connection_string = format!("dgraph://127.0.0.1:{port}");
    let client = connect_when_ready(&connection_string).await?;

    connects_and_probes(&client)?;
    sets_schema_and_round_trips_a_mutation(&client).await?;
    discard_rolls_back_a_mutation(&client).await?;
    best_effort_read_only_transaction_queries(&client).await?;
    upsert_applies_query_and_mutation_together(&client).await?;
    allocates_uid_ranges(&client).await?;
    run_dql_without_a_transaction(&client).await?;

    Ok(())
}

/// Connect and wait until the cluster can actually serve a query.
///
/// Two gates, because they are not the same thing:
///
/// 1. `connect()` must succeed. Its readiness probe is `CheckVersion`, and while the alpha
///    is starting that returns "server is not ready", which the client classifies as
///    `is_cluster_not_ready()`. Detecting it that way rather than by matching message text
///    is the whole point of the typed error surface.
/// 2. A trivial query must succeed. An alpha answers `CheckVersion` *before* it can serve
///    queries, so step 1 alone lets the suite start against a half-started cluster and die
///    later with `transport error`. That is the exact cold-start flake this loop closes:
///    treating "answers CheckVersion" as "ready" is simply wrong.
///
/// Only readiness-shaped failures are retried. Anything else aborts immediately rather
/// than being retried into a timeout that hides the real cause.
async fn connect_when_ready(connection_string: &str) -> Result<DgraphClient, String> {
    let mut last_error = None;

    for attempt in 1..=READY_ATTEMPTS {
        match DgraphClient::connect(connection_string).await {
            Ok(client) => match warm_up(&client).await {
                Ok(()) => return Ok(client),
                Err(err) => {
                    println!("attempt {attempt}: connected but not serving queries yet: {err}");
                    last_error = Some(err);
                }
            },
            Err(err) if err.is_cluster_not_ready() => {
                println!("attempt {attempt}: cluster not ready yet");
                last_error = Some(err.to_string());
            }
            Err(err) => return Err(format!("connect failed: {err}")),
        }

        tokio::time::sleep(READY_RETRY_DELAY).await;
    }

    Err(format!(
        "dgraph never became ready after {READY_ATTEMPTS} attempts: {}",
        last_error.unwrap_or_else(|| "no error recorded".to_string())
    ))
}

/// Prove the alpha will serve a real query, not just answer a version probe.
async fn warm_up(client: &DgraphClient) -> Result<(), String> {
    let mut txn = client.new_read_only_txn();
    txn.query("{ warmup(func: has(_predicate_)) { uid } }")
        .await
        .map(|_| ())
        .map_err(|err| err.to_string())
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
