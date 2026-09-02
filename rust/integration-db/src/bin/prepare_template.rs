/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Ensures the template database exists and reports whether it needs migrating.
//!
//! Run by BuildBuddy (`buildbuddy.yaml`) ahead of everything else. Two
//! jobs in one step, because both answer the same question and both are cheap:
//!
//!   1. create `sr_core_template` if absent, with extensions, AGE graphs and grants;
//!   2. compare the migration versions on disk against the template's `schema_migrations` in
//!      BOTH directions -- refusing outright when the template is AHEAD of this checkout, and
//!      otherwise emitting `needs_migration` so the workflow can skip
//!      `//elixir/serviceradar_core:migrate_template` entirely.
//!
//! That skip is the point of the whole arrangement. Starting the BEAM for an `ex_unit_test`
//! that depends on `serviceradar_core` costs 28.8-45.6s before a single line of test code
//! runs, and on a branch that touches no migrations there is nothing for it to do.
//!
//! # Why a binary and not a test
//!
//! It reports its result on stdout for the caller to branch on, and `bazel run` builds
//! eligible actions remotely while launching the binary on the caller, without depending on a
//! TestRunner placement strategy. That is exactly the split this needs.
//!
//! It used to append `needs_migration=<bool>` to `$GITHUB_OUTPUT` -- a GitHub Actions concept
//! BuildBuddy does not set, which the workflow faked with a temp file it then grepped. The
//! caller now branches on the line printed below, which is the same information without a
//! second channel or a CI vendor's name in this crate.

use anyhow::{Context, Result};
use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

fn main() -> Result<()> {
    let runtime = Runtime::new().context("failed to build a tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    // Owner of the template; the suite connects as this role against every clone of it. See
    // `db::database_owner` for why it is derived from the DSN rather than named here.
    let owner = db::database_owner()?;

    let state = db::template::ensure_template(&owner).await?;
    println!("template {}: {state:?}", db::template::TEMPLATE_DATABASE);

    let dir = db::template::migrations_dir();
    let drift = db::template::migration_drift(&dir).await?;

    // FAIL EARLY, and name them. The template is shared across branches and only ratchets
    // forward, so a branch that is BEHIND clones a FUTURE schema and runs its own resources
    // against it. `mix ecto.migrate` cannot see that -- a behind-branch has nothing PENDING, so
    // it reports "already up" -- and the suite then fails with constraint or undefined-column
    // errors that name no migration at all.
    //
    // Refusing here costs one line instead of a bisect, and it refuses BEFORE the suite runs
    // rather than in the middle of it.
    db::template::ensure_not_ahead(db::template::TEMPLATE_DATABASE, &drift)?;

    if drift.pending.is_empty() {
        println!("template is current; no migrations pending");
    } else {
        println!(
            "{} migration(s) pending, {} .. {}",
            drift.pending.len(),
            drift.pending[0],
            drift.pending[drift.pending.len() - 1]
        );
    }

    Ok(())
}
