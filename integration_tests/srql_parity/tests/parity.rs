//! The database-backed half of the harness: seeds a throwaway CNPG database and a throwaway
//! StarRocks database with the same synthetic rows, runs every `inventory.json` entry through
//! both SRQL dialects and fails on any result that differs from what the entry records.
//!
//! Configuration and safety rules are in `srql_parity::runner`. Run it with
//! `bazel test //integration_tests/srql_parity:parity_test` and the flags in BUILD.bazel.

use srql_parity::runner::{Outcome, run};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cnpg_and_starrocks_agree_on_every_inventoried_shape() {
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
