/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Provisions the per-lane integration databases, as physical copies of the run base.
//!
//! Replaces `scripts/reset-test-db.sh`. Runs after `//rust/integration-db:provision_base`
//! (and, when migrations are pending, `//elixir/serviceradar_core:migrate_run`), and before
//! the suite itself.
//!
//! This step used to create an empty database and install extensions into it, leaving the
//! 368 migrations to run per run. It now clones a base that already holds them, so the
//! schema arrives as a file copy and the BEAM is off the critical path entirely.
//!
//! The source used to be the shared template directly. It is the run base now, because a
//! branch's own migrations must be applied somewhere -- and applying them to the shared
//! template left them visible to every other branch, which wedged CI for everyone whose
//! checkout lacked them. See `src/template.rs`.
//!
//! # How this test functions
//!
//! One `#[test]` driving ordered steps, for the same reason
//! the Dgraph client's acceptance test does (github.com/marvin-hansen/dgraph-rs): both
//! cargo and Bazel run test
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

/// Shard names, comma-separated, from the Bazel target's `env`.
///
/// The CI target supplies every shard; focused `provision_db_sN` targets supply one.
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
    // The RUN BASE, not the shared template. //rust/integration-db:provision_base seeded it and
    // //elixir/serviceradar_core:migrate_run brought it up to this checkout; the lanes are
    // physical copies of it. The shared template is never a source here, which is what keeps a
    // branch's unmerged migrations out of state every other branch reads.
    let database = db::database_name()?;
    // The suite connects as this role, so it must own the database outright -- Ash creates
    // and drops tables during migrations. Derived from the DSN; see `db::database_owner`.
    let owner = db::database_owner()?;

    // Fail loudly rather than cloning a base that does not match the migrations on disk: the
    // suite would then run against a schema that does not match the code under test, and the
    // failures would point anywhere but here. Both directions, and both are broken invariants
    // by this point -- provision_base and migrate_run run immediately before this step.
    let drift =
        db::template::migration_drift_of(&database, &db::template::migrations_dir()).await?;
    db::template::ensure_current(&database, &drift)?;

    // One database per selected shard. The suite runs as parallel Bazel targets and Ecto's SQL
    // sandbox does not isolate across OS processes, so sharing one database deadlocks. Shard
    // names arrive through the target environment from //build:integration_shards.bzl, which
    // the Elixir side reads as SERVICERADAR_TEST_DB_SHARD -- both derive the same names from it.
    //
    // No shards means the suite runs against the base itself, which keeps the target usable by
    // hand. There is nothing to clone in that case: provision_base already built it.
    let shards = shards()?;

    if shards.is_empty() {
        println!("no shards selected; the suite runs against the run base {database} directly");
    } else {
        println!(
            "cloning {} shard database(s) from run base {database} (owner {owner})",
            shards.len(),
        );

        for shard in &shards {
            let name = db::shard_database_name(shard)?;
            println!("  {name}");
            db::template::clone_database(&database, &name, &owner).await?;
        }
    }

    // Report the URL the following steps will derive, so a mismatch is visible in the log
    // rather than surfacing as a confusing connection error two targets later. Credentials
    // are not printed.
    let url = db::database_url()?;
    let redacted = db::redacted_database_url(&url);
    println!("suite will connect to {redacted}");

    Ok(())
}
