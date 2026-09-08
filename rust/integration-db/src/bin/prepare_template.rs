/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Ensures the template database exists and reports whether it needs migrating.
//!
//! Run by BuildBuddy (`buildbuddy.yaml`) from the TRUNK lifecycle only -- the action that
//! triggers on a push to `staging` -- because advancing the shared template is a write to
//! state every branch reads, and only trunk's migrations belong there. A pull request calls
//! `//rust/integration-db:provision_base` instead, which seeds a per-run database and leaves
//! the template alone. See `src/template.rs` for what made that split necessary.
//!
//! "Only" is enforced, not merely arranged: this refuses to run without
//! `--//build:template_authority=true`. Being named from one action is a convention a later
//! edit undoes silently, and one a workstation never obeyed at all -- see
//! `db::require_template_authority`.
//!
//! Two jobs in one step, because both answer the same question and both are cheap:
//!
//!   1. create `sr_core_template` if absent, with extensions, AGE graphs and grants;
//!   2. compare the migration versions on disk against the template's `schema_migrations` in
//!      BOTH directions, reporting the status on stdout so the workflow can skip
//!      `//elixir/serviceradar_core:migrate_template` entirely, or invalidate a template that
//!      has diverged from trunk.
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
    // Trunk, or nothing. Creating and reporting on the shared template is the trunk lifecycle's
    // entry point, and the flag is what makes "only trunk runs this" a property of the target
    // rather than of where it happens to be named in `buildbuddy.yaml`.
    db::require_template_authority("//rust/integration-db:prepare_template")?;

    // Owner of the template; the suite connects as this role against every clone of it. See
    // `db::database_owner` for why it is derived from the DSN rather than named here.
    let owner = db::database_owner()?;

    let state = db::template::ensure_template(&owner).await?;
    println!("template {}: {state:?}", db::template::TEMPLATE_DATABASE);

    let dir = db::template::migrations_dir();
    let drift = db::template::migration_drift(&dir).await?;

    // REPORT, and name them. `mix ecto.migrate` cannot report migrations already applied to the
    // template but absent from this checkout: a strictly behind checkout has a pending set that
    // is empty, so it reports "already up" and the suite then fails with constraint or
    // undefined-column errors that name no migration at all. Naming them here costs one line
    // instead of a bisect.
    //
    // On trunk this means the template holds migrations that are on no merged branch, and the
    // caller invalidates it -- `migrate_template` cannot un-apply anything, so running it
    // against an ahead template would report success and change nothing.
    if let db::template::TemplateFitness::Ahead { extra_applied } =
        db::template::template_fitness(&drift)
    {
        eprintln!(
            "{}",
            db::template::ahead_report(db::template::TEMPLATE_DATABASE, &extra_applied)
        );
        println!("template is AHEAD of this checkout");
        return Ok(());
    }

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
