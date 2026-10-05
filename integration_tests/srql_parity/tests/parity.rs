//! The database-backed half of the harness: seeds a throwaway CNPG database and a throwaway
//! StarRocks database with the same synthetic rows, runs every `inventory.json` entry through
//! both SRQL dialects and fails on any result that differs from what the entry records.
//!
//! Configuration and safety rules are in `srql_parity::runner`. Run it with
//! `bazel test //integration_tests/srql_parity:parity_test` and the flags in BUILD.bazel.

use anyhow::{Result, ensure};
use mysql_async::prelude::Queryable;
use srql_parity::runner::{Outcome, fixed_database_allowed, run};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cnpg_and_starrocks_agree_on_every_inventoried_shape() {
    busy_fixture_survives_refused_run()
        .await
        .expect("busy fixture protection failed");
    let outcomes = run().await.expect("parity harness setup failed");
    let mut failures = 0;
    println!("\n{:-<100}", "");
    for (id, outcome) in &outcomes {
        match outcome {
            Outcome::Pass(note) => println!("PASS  {id:<58} {note}"),
            Outcome::Fail(why) => {
                failures += 1;
                println!("FAIL  {id:<58} {why}");
            }
        }
    }
    println!("{:-<100}", "");
    println!(
        "{} entries, {} passed, {failures} failed",
        outcomes.len(),
        outcomes.len() - failures
    );
    assert!(!outcomes.is_empty(), "no inventory entry ran");
    assert_eq!(
        failures, 0,
        "{failures} inventory entries failed; see the report above"
    );
}

// Exercise the actual runner before the inventory, serially on the same
// fixture. A refusal must preserve the previous owner's table and row.
async fn busy_fixture_survives_refused_run() -> Result<()> {
    let Ok(database) = std::env::var("SRQL_PARITY_STARROCKS_DATABASE") else {
        return Ok(());
    };
    let database = database.trim();
    ensure!(fixed_database_allowed(database), "invalid fixed fixture name");
    ensure!(
        std::env::var("SRQL_PARITY_KEEP").as_deref() != Ok("1"),
        "busy fixture regression requires cleanup"
    );
    let options = mysql_async::OptsBuilder::default()
        .ip_or_hostname(std::env::var("SRQL_PARITY_STARROCKS_HOST")?)
        .tcp_port(std::env::var("SRQL_PARITY_STARROCKS_PORT")?.parse()?)
        .user(Some(std::env::var("SRQL_PARITY_STARROCKS_USER")?))
        .pass(std::env::var("SRQL_PARITY_STARROCKS_PASSWORD").ok())
        .pool_opts(mysql_async::PoolOpts::default().with_reset_connection(false))
        .prefer_socket(false);
    let pool = mysql_async::Pool::new(options);
    let mut conn = pool.get_conn().await?;
    let count: Option<u64> = conn
        .query_first(format!(
            "SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA = '{database}'"
        ))
        .await?;
    ensure!(count == Some(0), "fixture is occupied; refusing canary DDL");
    let table = format!("{database}.fixture_busy_canary");
    conn.query_drop(format!(
        "CREATE TABLE {table} (marker INT) DUPLICATE KEY(marker) \
         DISTRIBUTED BY HASH(marker) BUCKETS 1 PROPERTIES ('replication_num' = '1')"
    ))
    .await?;
    let result = async {
        conn.query_drop(format!("INSERT INTO {table} VALUES (7)"))
            .await?;
        let refusal = match run().await {
            Err(error) => error,
            Ok(_) => anyhow::bail!("runner accepted an occupied fixture"),
        };
        ensure!(
            format!("{refusal:#}").contains("holds objects created within"),
            "runner failed without reporting the busy fixture"
        );
        let marker: Option<i32> = conn
            .query_first(format!("SELECT marker FROM {table}"))
            .await?;
        ensure!(marker == Some(7), "refused run changed the existing fixture");
        Ok::<_, anyhow::Error>(())
    }
    .await;
    // Only this test's table is ours to remove, including on assertion failure.
    conn.query_drop(format!("DROP TABLE IF EXISTS {table} FORCE"))
        .await?;
    let remaining: Option<u64> = conn
        .query_first(format!(
            "SELECT COUNT(*) FROM information_schema.tables WHERE TABLE_SCHEMA = '{database}'"
        ))
        .await?;
    ensure!(remaining == Some(0), "canary cleanup left fixture objects");
    drop(conn);
    pool.disconnect().await?;
    result?;
    println!("PASS  busy fixture refusal preserves the previous owner's table and row");
    Ok(())
}
