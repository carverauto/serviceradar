/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Provisions the per-run integration database, as a physical copy of the template.
//!
//! Replaces `scripts/reset-test-db.sh`. Runs after
//! `//rust/integration-db:prepare_template` (and, when migrations are pending,
//! `//elixir/serviceradar_core:migrate_template`), and before the suite itself.
//!
//! This step used to create an empty database and install extensions into it, leaving the
//! 368 migrations to run per run. It now clones a template that already holds them, so the
//! schema arrives as a file copy and the BEAM is off the critical path entirely.
//!
//! # How this test functions
//!
//! One `#[test]` driving ordered steps, for the same reason
//! `rust/dgraph-client/tests/dgraph_container_test.rs` does: both cargo and Bazel run test
//! *functions* concurrently and neither honours `--test-threads=1` in CI regardless of
//! tagging. Separate `#[test]`s would race, and these steps are DDL against one database.
//!
//! A plain `#[test]` driving one explicit runtime, rather than `#[tokio::test]`, so the
//! runtime's lifetime is visible and the connection tasks outlive every query.
//!
//! # Why it is not `#[ignore]`
//!
//! The dgraph suite marks itself `#[ignore]` because Docker may legitimately be absent. Here
//! the opposite holds: the Bazel target is `manual` + `external`, so it only ever runs when
//! the workflow asks for it, and at that point a missing fixture is a failure to report, not
//! a reason to skip. A silent skip would let the whole integration job go green having
//! provisioned nothing.

use anyhow::Result;
use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

/// Owner of the created database. The suite connects as this role, so it must own the
/// database outright -- Ash creates and drops tables during migrations.
const DEFAULT_OWNER: &str = "serviceradar";

/// Shard names, comma-separated, from the Bazel target's `env`.
///
/// Deliberately NOT Bazel `args`: libtest treats a bare argv entry as a test-name FILTER, so
/// passing shard names that way made it match no test, run nothing, and exit 0. The target
/// went green having provisioned zero databases -- the exact failure `external` exists to
/// prevent, arriving through a different door.
fn shards() -> Result<Vec<String>> {
    let raw = match std::env::var("SERVICERADAR_TEST_DB_SHARDS") {
        Ok(value) => value,
        Err(_) => return Ok(Vec::new()),
    };

    let shards: Vec<String> = raw
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();

    // Set-but-unparseable means the shard list was wired up wrong. Falling back to the
    // unsharded database would provision one database for eight targets, and seven of them
    // would fail to connect two steps later.
    if shards.is_empty() {
        anyhow::bail!("SERVICERADAR_TEST_DB_SHARDS is set to {raw:?} but names no shards");
    }

    Ok(shards)
}

#[test]
fn provisions_the_integration_database() {
    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run());

    if let Err(err) = &outcome {
        eprintln!("FAILED: {err:?}");
    }

    outcome.expect("provisioning failed");
}

async fn run() -> anyhow::Result<()> {
    let database = db::database_name()?;
    let owner = std::env::var("SERVICERADAR_TEST_DATABASE_OWNER")
        .unwrap_or_else(|_| DEFAULT_OWNER.to_string());

    // Fail loudly rather than cloning a template that is behind the migrations on disk: the
    // suite would then run against a schema that does not match the code under test, and the
    // failures would point anywhere but here.
    let pending = db::template::pending_versions(&db::template::migrations_dir()).await?;
    if !pending.is_empty() {
        anyhow::bail!(
            "template {} is behind by {} migration(s), starting at {}; run \
             //elixir/serviceradar_core:migrate_template first",
            db::template::TEMPLATE_DATABASE,
            pending.len(),
            pending[0]
        );
    }

    // One database per shard. The suite runs as parallel Bazel targets and Ecto's SQL sandbox
    // does not isolate across OS processes, so sharing one database deadlocks. Shard names
    // arrive as test args from //build:integration_shards.bzl, which the Elixir side reads as
    // SERVICERADAR_TEST_DB_SHARD -- both derive the same names from it.
    //
    // No args means the unsharded database, which keeps the target usable by hand.
    let shards = shards()?;

    if shards.is_empty() {
        println!(
            "cloning {database} from {} (owner {owner})",
            db::template::TEMPLATE_DATABASE
        );
        db::template::clone_from_template(&database, &owner).await?;
    } else {
        println!(
            "cloning {} shard database(s) from {} (owner {owner})",
            shards.len(),
            db::template::TEMPLATE_DATABASE
        );

        for shard in &shards {
            let name = db::shard_database_name(shard)?;
            println!("  {name}");
            db::template::clone_from_template(&name, &owner).await?;
        }
    }

    // Report the URL the following steps will derive, so a mismatch is visible in the log
    // rather than surfacing as a confusing connection error two targets later. Credentials
    // are not printed.
    let url = db::database_url()?;
    let redacted = url
        .split_once("://")
        .map(|(scheme, rest)| match rest.split_once('@') {
            Some((_, host)) => format!("{scheme}://***@{host}"),
            None => format!("{scheme}://{rest}"),
        })
        .unwrap_or_else(|| "<unparseable>".to_string());
    println!("suite will connect to {redacted}");

    Ok(())
}
