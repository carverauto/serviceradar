/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Ensures the template database exists and reports whether it needs migrating.
//!
//! Run by `.forgejo/workflows/elixir-integration-sr-core.yml` ahead of everything else. Two
//! jobs in one step, because both answer the same question and both are cheap:
//!
//!   1. create `sr_core_template` if absent, with extensions, AGE graphs and grants;
//!   2. compare the migration versions on disk against the template's `schema_migrations`,
//!      and emit `needs_migration` so the workflow can skip
//!      `//elixir/serviceradar_core:migrate_template` entirely.
//!
//! That skip is the point of the whole arrangement. Starting the BEAM for an `ex_unit_test`
//! that depends on `serviceradar_core` costs 28.8-45.6s before a single line of test code
//! runs, and on a branch that touches no migrations there is nothing for it to do.
//!
//! # Why a binary and not a test
//!
//! It has to write to `$GITHUB_OUTPUT` on the runner. `bazel run` builds eligible actions
//! remotely and launches the binary on the caller, where that output file exists, without
//! depending on a TestRunner placement strategy. That is exactly the split this needs.
//!
//! Outside CI `GITHUB_OUTPUT` is unset and the result is only printed, which keeps the
//! binary usable by hand against a developer fixture.

use std::fs::OpenOptions;
use std::io::Write;

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
    let pending = db::template::pending_versions(&dir).await?;

    if pending.is_empty() {
        println!("template is current; no migrations pending");
    } else {
        println!(
            "{} migration(s) pending, {} .. {}",
            pending.len(),
            pending[0],
            pending[pending.len() - 1]
        );
    }

    emit(!pending.is_empty())
}

/// Append `needs_migration=<bool>` to `$GITHUB_OUTPUT`, when running under CI.
fn emit(needs_migration: bool) -> Result<()> {
    let Ok(path) = std::env::var("GITHUB_OUTPUT") else {
        return Ok(());
    };
    if path.is_empty() {
        return Ok(());
    }

    let mut file = OpenOptions::new()
        .append(true)
        .create(true)
        .open(&path)
        .with_context(|| format!("failed to open GITHUB_OUTPUT at {path}"))?;

    writeln!(file, "needs_migration={needs_migration}")
        .with_context(|| format!("failed to write to GITHUB_OUTPUT at {path}"))?;

    Ok(())
}
