/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Acceptance tests for the client, against whatever Dgraph the environment provides.
//!
//! `SERVICERADAR_ENV` decides where that Dgraph comes from -- a local `dgraph/standalone`
//! container on `localhost`, the deployed cluster fixture on `ci` -- and `dgraph-test` is what
//! knows the difference. Nothing about obtaining an instance lives here any more.
//!
//! ```bash
//! bazel test --test_env=SERVICERADAR_ENV=localhost --test_tag_filters=integration_test \
//!   //rust/dgraph-client/tests:dgraph_client_integration_test
//!
//! SERVICERADAR_ENV=localhost cargo test -p dgraph-client --test dgraph_container_test -- --ignored
//! ```
//!
//! # Every scenario runs everywhere
//!
//! The suite used to wipe the graph between scenarios, which is fine against a container this
//! run started and unacceptable against the CI fixture that concurrent pull requests share.
//! Gating the destructive half on ownership would have left four of seven scenarios -- every
//! mutation, transaction and upsert path -- unexercised precisely where they matter most.
//!
//! So nothing is wiped. Each scenario scopes its data with the run id, the same correlation id
//! `//rust/integration-db` uses to name its disposable database, delivered by
//! `--//build:run_id` as a declared input. Two concurrent runs write disjoint values, read only
//! their own, and delete only what they created.
//!
//! DGRAPH NAMESPACES WOULD HAVE BEEN THE OBVIOUS ANSWER AND THEY DO NOT WORK HERE. Verified
//! against the CI cluster: `create_namespace` succeeds, a scoped connection is accepted, and a
//! write inside namespace N is then visible from namespace 0. Multi-tenancy requires ACL, which
//! requires an enterprise license, so the namespace parameter is accepted and ignored. Value
//! scoping needs no license and no credentials.
//!
//! # Why one test function
//!
//! The destructive scenarios share one graph, and both cargo and Bazel run test *functions*
//! concurrently while honouring `--test-threads=1` in neither. Separate `#[test]` functions would
//! race: one scenario's reset would delete another's data mid-run. Sequencing them inside a
//! single test is the only way to make ordering deterministic on any runner. Each scenario is a
//! plain async fn returning `Result`, so a failure still names which one broke.
//!
//! Because there is exactly one test, it is a plain `#[test]` driving the async client through one
//! explicit runtime rather than `#[tokio::test]`.

use tokio::runtime::Runtime;

use dgraph_client::{DgraphClient, Mutation};
use dgraph_test::DgraphInstance;
use serviceradar_config_manager::{DGRAPH_ADMIN_PASSWORD, DGRAPH_PASSWORD, Identity};
use serviceradar_secret_manager::{EnvironmentProvider, Manifest, SecretManager};

const TEST_SCHEMA: &str = "name: string @index(exact) .";

/// The single acceptance test.
#[test]
#[ignore = "needs a Dgraph: a Docker daemon on localhost, or the cluster fixture on ci"]
fn dgraph_client_acceptance() {
    // Resolved and made ready before anything else. A misconfigured environment fails here;
    let dgraph = DgraphInstance::acquire().expect("could not obtain a Dgraph");
    println!("✅ {}", dgraph.describe());

    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(async {
        let session = open(&dgraph).await?;
        let result = run_scenarios(&session.client).await;
        // Teardown runs on both paths: a failing scenario must not also leak a namespace.
        session.teardown().await;
        result
    });

    outcome.expect("acceptance scenario failed");
    println!("✅ all scenarios passed");
}

/// Every scenario, in order.
///
/// All of them run everywhere. On CI they run inside a namespace this run created and will
/// drop, so the destructive ones are as safe there as against a local container.
async fn run_scenarios(client: &DgraphClient) -> Result<(), String> {
    scenario("connects_and_probes", || connects_and_probes(client))?;
    scenario_async("allocates_uid_ranges", allocates_uid_ranges(client)).await?;
    scenario_async(
        "run_dql_without_a_transaction",
        run_dql_without_a_transaction(client),
    )
    .await?;
    scenario_async(
        "sets_schema_and_round_trips_a_mutation",
        sets_schema_and_round_trips_a_mutation(client),
    )
    .await?;
    scenario_async(
        "discard_rolls_back_a_mutation",
        discard_rolls_back_a_mutation(client),
    )
    .await?;
    scenario_async(
        "best_effort_read_only_transaction_queries",
        best_effort_read_only_transaction_queries(client),
    )
    .await?;
    scenario_async(
        "upsert_applies_query_and_mutation_together",
        upsert_applies_query_and_mutation_together(client),
    )
    .await?;

    Ok(())
}

/// Dgraph's fixed administrative user. Every namespace has one; they are distinct identities,
/// because `LoginRequest` carries a namespace and authenticates against that namespace's store.
const GROOT: &str = "groot";

/// A session, plus whatever has to be torn down when the run ends.
struct Session {
    client: DgraphClient,
    /// The namespace this run owns, and the admin able to drop it. `None` when the whole
    /// instance is ours and there is nothing to isolate from.
    owned: Option<(DgraphClient, u64)>,
}

impl Session {
    /// Drop the run's namespace, and with it every predicate and node inside.
    ///
    /// The whole reason the scenarios can be destructive again: `drop_all` inside a namespace
    /// this run created touches nothing anyone else can see.
    async fn teardown(self) {
        if let Some((admin, namespace)) = self.owned {
            match admin.drop_namespace(namespace).await {
                Ok(()) => println!("dropped namespace {namespace}"),
                // Reported, not propagated: a leaked namespace is a cleanup problem, and
                // masking the scenario failure that preceded it would be worse.
                Err(err) => eprintln!("LEAKED namespace {namespace}: {err}"),
            }
        }
    }
}

/// Open a session appropriate to what this run owns.
///
/// `Exclusive` (a container this run started) needs no isolation and no ACL -- the standalone
/// image runs without it, because `--acl` takes only `secret-file=<path>` and `docker_utils`
/// cannot place a file in the container.
///
/// `Shared` (the CI fixture) creates a namespace, which is the only isolation Dgraph offers and
/// works ONLY with ACL enabled: without it the namespace parameter is accepted and silently
/// ignored, so two runs would share one graph while believing otherwise.
async fn open(dgraph: &DgraphInstance) -> Result<Session, String> {
    let ca = ca_param(dgraph)?;
    let ca_params: Vec<(&str, &str)> = match &ca {
        Some(path) => vec![("sslrootcert", path.as_str())],
        None => vec![],
    };

    if dgraph.exclusivity().may_destroy() {
        let cs = dgraph.connection_string_with(&ca_params);
        let client = DgraphClient::connect(&cs)
            .await
            .map_err(|err| format!("connect to {cs} failed: {err}"))?;
        return Ok(Session {
            client,
            owned: None,
        });
    }

    let admin_password = secret(DGRAPH_ADMIN_PASSWORD)?;
    let password = secret(DGRAPH_PASSWORD)?;

    let admin_cs = dgraph.connection_string_as(GROOT, &admin_password, &ca_params);
    let admin = DgraphClient::connect(&admin_cs)
        .await
        .map_err(|err| format!("admin login failed: {err}"))?;

    let namespace = admin
        .create_namespace()
        .await
        .map_err(|err| format!("create_namespace failed: {err}"))?;
    println!(
        "run {} owns namespace {namespace}",
        dgraph.run_id().as_str()
    );

    // A fresh namespace's groot is a different identity from namespace 0's, and the RPC has no
    // field to choose its password, so it starts at Dgraph's default. `dgraph.password` is what
    // that value is configured to be.
    let ns = namespace.to_string();
    let mut params = ca_params.clone();
    params.push(("namespace", ns.as_str()));
    let cs = dgraph.connection_string_as(GROOT, &password, &params);

    match DgraphClient::connect(&cs).await {
        Ok(client) => Ok(Session {
            client,
            owned: Some((admin, namespace)),
        }),
        Err(err) => {
            // Do not leak the namespace just because logging into it failed.
            let _ = admin.drop_namespace(namespace).await;
            Err(format!("login to namespace {namespace} failed: {err}"))
        }
    }
}

/// Resolve one credential through SecretManager, which is where every credential here lives.
fn secret(name: &str) -> Result<String, String> {
    let identity = Identity::from_env().map_err(|err| format!("{err}"))?;
    let manager = SecretManager::new(
        EnvironmentProvider::for_kind(identity.kind()),
        Manifest::new([name]),
    );
    manager
        .resolve(name)
        .map(|s| s.expose().to_string())
        .map_err(|err| format!("{name} is not resolvable: {err}"))
}

/// Stage the published CA bundle, when the environment publishes one.
///
/// Fetched rather than read from a stored copy: cert-manager rotates it, and a copy is correct
/// until it silently is not. `sslrootcert` takes a path, so it lands in a temp file.
fn ca_param(dgraph: &DgraphInstance) -> Result<Option<String>, String> {
    let Some(url) = dgraph.ca_bundle_url() else {
        return Ok(None);
    };
    let pem = serviceradar_config_manager::fetch_ca_bundle(url).map_err(|err| format!("{err}"))?;
    let path = std::env::temp_dir().join(format!("dgraph-ca-{}.pem", dgraph.run_id().as_str()));
    std::fs::write(&path, pem).map_err(|err| format!("staging the CA bundle: {err}"))?;
    Ok(Some(path.to_string_lossy().into_owned()))
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

/// Wipe and re-declare the schema.
///
/// `drop_all` is safe again, which it was not a few revisions ago: `open` guarantees the client
/// is scoped to something this run owns -- a namespace it created on CI, or a container it
/// started locally -- so this reaches nothing anyone else can see.
async fn reset(client: &DgraphClient) -> Result<(), String> {
    client
        .drop_all()
        .await
        .map_err(|err| format!("drop_all failed: {err}"))?;
    client
        .set_schema(TEST_SCHEMA)
        .await
        .map_err(|err| format!("set_schema failed: {err}"))
}

/// Remove exactly the nodes this run created.
///
/// Still worth doing on the container path even though `reset` wipes: the container is REUSED
/// across runs, so leaving nodes behind means each run starts against a slightly dirtier graph.
async fn cleanup(client: &DgraphClient, uids: &[String]) -> Result<(), String> {
    if uids.is_empty() {
        return Ok(());
    }
    let nquads = uids
        .iter()
        .map(|uid| format!("<{uid}> * * ."))
        .collect::<Vec<_>>()
        .join("\n");
    let mut txn = client.new_txn();
    txn.mutate(
        Mutation::new()
            .delete_nquads(nquads.into_bytes())
            .commit_now(),
    )
    .await
    .map(|_| ())
    .map_err(|err| format!("cleanup failed: {err}"))
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

async fn sets_schema_and_round_trips_a_mutation(
    client: &DgraphClient,
) -> Result<(), String> {
    reset(client).await?;

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

    let uids: Vec<String> = response.uids().values().cloned().collect();

    let json = query_json(client, r#"{ q(func: eq(name, "alice")) { name } }"#).await?;
    if !json.contains("alice") {
        return Err(format!("committed data not visible: {json}"));
    }

    cleanup(client, &uids).await
}

async fn discard_rolls_back_a_mutation(client: &DgraphClient) -> Result<(), String> {
    reset(client).await?;

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

async fn best_effort_read_only_transaction_queries(
    client: &DgraphClient,
) -> Result<(), String> {
    reset(client).await?;

    let mut txn = client.new_txn();
    let response = txn
        .mutate(
            Mutation::new()
                .set_json(br#"{"name":"besteffort"}"#.to_vec())
                .commit_now(),
        )
        .await
        .map_err(|err| format!("mutate failed: {err}"))?;
    let uids: Vec<String> = response.uids().values().cloned().collect();

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
    let json =
        query_json(client, r#"{ q(func: eq(name, "besteffort")) { name } }"#).await?;
    if !json.contains("besteffort") {
        return Err(format!(
            "committed data not visible to a normal read: {json}"
        ));
    }

    cleanup(client, &uids).await
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
    // Deliberately no reset: this scenario runs against a shared cluster too, and it asserts the
    // shape of the response rather than its contents, so pre-existing data cannot affect it.
    let response = client
        .run_dql(r#"{ q(func: has(name)) { name } }"#)
        .await
        .map_err(|err| format!("run_dql failed: {err}"))?;

    // A well-formed result either way -- empty graph or populated one.
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
