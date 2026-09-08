/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Creates this run's base database and reports whether it still needs migrating.
//!
//! The base is `sr_core_test_<run>`: one database per run, seeded from the shared template
//! when that template is a safe seed, and built from nothing when it is not. Every lane
//! database is then a physical copy of it.
//!
//! # Why the base exists at all
//!
//! A branch that adds migrations has to apply them somewhere. Until now that somewhere was
//! the SHARED template, because `//elixir/serviceradar_core:migrate_template` was invoked by
//! whichever run reached it first -- and BazelCI triggers on `pull_request` only, so the
//! first run was always a branch whose migrations were unmerged. Those migrations then sat in
//! state every other branch reads, and every later run whose checkout lacked them was refused.
//! One branch left seven such migrations behind and every other pull request went red on a
//! step that had nothing to do with its diff.
//!
//! Applying them to a per-run database instead costs one `CREATE DATABASE ... TEMPLATE` on
//! every run, and the BEAM only on the runs that actually add a migration. The shared
//! template stays a read-only cache of trunk's schema for everyone else.
//!
//! # Why a binary and not a test
//!
//! Same reason as `prepare_template`: it reports its result on stdout for the caller to branch
//! on, and `bazel run` builds eligible actions remotely while launching the binary on the
//! caller, without depending on a TestRunner placement strategy.

use anyhow::{Context, Result};
use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

fn main() -> Result<()> {
    let runtime = Runtime::new().context("failed to build a tokio runtime")?;
    runtime.block_on(run())
}

async fn run() -> Result<()> {
    let owner = db::database_owner()?;
    let base = db::database_name()?;
    let dir = db::template::migrations_dir();

    // Idempotent and advisory-locked. Creating it here rather than in a separate step means a
    // run never has to be ordered against "has anyone made the template yet"; an absent
    // template is simply a cache miss whose drift reports every migration as pending.
    let state = db::template::ensure_template(&owner).await?;
    println!("template {}: {state:?}", db::template::TEMPLATE_DATABASE);

    let template_drift = db::template::migration_drift(&dir).await?;

    match db::template::template_fitness(&template_drift) {
        db::template::TemplateFitness::Usable => {
            println!(
                "seeding run base {base} from {}",
                db::template::TEMPLATE_DATABASE
            );
            db::template::clone_database(db::template::TEMPLATE_DATABASE, &base, &owner).await?;
        }
        db::template::TemplateFitness::Ahead { extra_applied } => {
            // Loud, and on stderr, because this is a degraded run: it will pay a full schema
            // build. It is NOT a failure -- the base is built from this checkout's own
            // migrations, which is strictly more correct than cloning a future schema, and the
            // shared template is left exactly as it was found.
            eprintln!(
                "{}",
                db::template::ahead_report(db::template::TEMPLATE_DATABASE, &extra_applied)
            );
            println!("seeding run base {base} from nothing (template unusable)");
            db::template::create_scratch(&base, &owner).await?;
        }
    }

    // Drift of the BASE, not the template. After a clone the two agree; after a scratch build
    // every migration is pending. Either way this is the line the caller branches on, and it
    // describes the database the migrator would actually be pointed at.
    let drift = db::template::migration_drift_of(&base, &dir).await?;

    if drift.pending.is_empty() {
        println!("run base is current; no migrations pending");
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
