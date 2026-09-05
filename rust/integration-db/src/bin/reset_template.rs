/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Drops the shared template, so the next trunk run rebuilds it from staging.
//!
//! The one deliberate exception to the rule that nothing may touch `sr_core_template` outside
//! the migrate path: `assert_disposable` refuses the name everywhere else, which is what keeps
//! teardown and the stale sweep off it.
//!
//! # When this is the right thing to run
//!
//! The template is a CACHE of trunk's schema. It can hold migrations trunk does not have --
//! a branch that advanced it before this fix landed, a migration reverted on staging, a
//! hand-run migrator. A run whose checkout lacks those migrations cannot clone it and pays a
//! full schema build instead, every time, until the cache is invalidated. That is what this
//! target does.
//!
//! `buildbuddy.yaml` runs it automatically from the trunk lifecycle when the template is
//! reported AHEAD, which is the only context where "ahead of this checkout" and "ahead of the
//! schema of record" are the same statement. It is deliberately NOT run from a pull request:
//! a branch must not be able to destroy state every other branch reads, which is the class of
//! bug that made this target necessary -- so it refuses without
//! `--//build:template_authority=true` rather than trusting where it is named.
//!
//! # Why it does not force
//!
//! `DROP DATABASE` without `WITH (FORCE)` fails while any session is connected, and that is
//! the wanted behaviour: a session on the template is either another run cloning from it or a
//! migration in flight, and killing the second leaves a half-applied schema that the next
//! attempt trips over. It retries on the clone path's schedule and then reports.

use anyhow::{Context, Result};
use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

fn main() -> Result<()> {
    let runtime = Runtime::new().context("failed to build a tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    // The most destructive target in this crate: it DROPS state every other run reads. Trunk is
    // the only checkout for which "ahead of this checkout" and "ahead of the schema of record"
    // are the same statement, so trunk is the only checkout that may decide the cache is wrong.
    db::require_template_authority("//rust/integration-db:reset_template")?;

    if db::template::reset_template().await? {
        println!(
            "dropped template {}; the next run rebuilds it",
            db::template::TEMPLATE_DATABASE
        );
    } else {
        println!(
            "template {} does not exist; nothing to reset",
            db::template::TEMPLATE_DATABASE
        );
    }

    Ok(())
}
