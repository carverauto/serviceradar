/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

//! Drops leftover fixture databases left behind by earlier runs.
//!
//! Replaces `scripts/sweep-stale-core-test-dbs.sh`. Teardown only runs when a job reaches
//! it; a cancelled run or a dead runner leaks its database, and the fixture is shared, so
//! something has to collect them.
//!
//! Runs first, before provisioning, so a fixture that has accumulated debris is cleaned
//! before this run adds to it.

use serviceradar_integration_db as db;
use tokio::runtime::Runtime;

/// Only databases older than this are swept. Generous on purpose: a database younger than
/// this may belong to a concurrent pull request that is still running.
const MAX_AGE_SECS: i64 = 86_400;

#[test]
fn sweeps_stale_integration_databases() {
    let runtime = Runtime::new().expect("failed to build a tokio runtime");
    let outcome = runtime.block_on(run());

    if let Err(err) = &outcome {
        eprintln!("FAILED: {err:?}");
    }

    outcome.expect("sweep failed");
}

async fn run() -> anyhow::Result<()> {
    let dropped = db::sweep_stale(MAX_AGE_SECS).await?;

    if dropped.is_empty() {
        println!("no stale integration databases");
    } else {
        println!("dropped {} stale database(s):", dropped.len());
        for name in dropped {
            println!("  {name}");
        }
    }

    Ok(())
}
