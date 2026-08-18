/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Drops the per-run integration database.
//!
//! Replaces `scripts/drop-test-db.sh`. Runs last, pass or fail, so a red suite does not leak
//! its database.
//!
//! This is the fast path, not the only one. A cancelled job or a dead runner never reaches
//! this target at all, which is why the workflow keeps a cleanup step and
//! `sweep_stale_dbs_test` exists.
//!
//! The database name is re-read from `//build:run_id_file` rather than handed over from the
//! provisioning step, so there is no state to lose between targets. Teardown drops databases,
//! so it is the step that most needs that name to be a declared input rather than whatever the
//! environment happened to hold.

use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

#[test]
fn drops_the_integration_database() {
    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run());

    if let Err(err) = &outcome {
        eprintln!("FAILED: {err:?}");
    }

    outcome.expect("teardown failed");
}

async fn run() -> anyhow::Result<()> {
    // Every database this run created: the unsharded name and each `<name>_<shard>`.
    //
    // Discovered by query rather than from the shard list, so a shard count that changed
    // between provision and teardown -- a rebased branch, a retried attempt against an older
    // build -- still leaves nothing behind on the shared fixture.
    let dropped = db::teardown_run().await?;

    if dropped.is_empty() {
        println!("nothing to drop for {}", db::database_name()?);
    } else {
        println!("dropped {} database(s):", dropped.len());
        for name in dropped {
            println!("  {name}");
        }
    }

    Ok(())
}
