/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Traversable Example
//!
//! NOTE: VecWitness Traversable is currently disabled due to constraint system
//! complexity. This example demonstrates OptionWitness and ResultWitness Traversable
//! with simple manual flipping patterns.

use deep_causality_haft::{Functor, OptionWitness};

fn main() {
    println!("=== DeepCausality HKT: Batch Aggregation ===\n");

    // ------------------------------------------------------------------------
    // Concept: Traversable (Flipping Structure)
    //
    // ENGINEERING VALUE:
    // When processing a batch of items, you often end up with a "List of Results"
    // (Vec<Result<T, E>>).
    //
    // However, for an atomic operation, you often want a "Result of a List"
    // (Result<Vec<T>, E>). i.e., "Give me all the data, or fail if any is missing."
    //
    // This example demonstrates manual sequence patterns.
    // ------------------------------------------------------------------------

    println!("--- 1. Atomic Batch Retrieval (All or Nothing) ---");

    // Scenario: Fetching Users by ID.
    let fetch_user = |id: u32| -> Option<User> {
        if id == 404 {
            None // User not found
        } else {
            Some(User {
                id,
                name: format!("User_{}", id),
            })
        }
    };

    // Case A: All users exist
    let batch_ids_ok = vec![1, 2, 3];
    let results_ok: Vec<Option<User>> = batch_ids_ok.into_iter().map(fetch_user).collect();
    println!("Raw Results (OK): {:?}", results_ok);

    // Manual sequence: Vec<Option<User>> -> Option<Vec<User>>
    let atomic_batch_ok: Option<Vec<User>> = sequence_option(results_ok);

    println!("Atomic Batch (OK): {:#?}", atomic_batch_ok);
    assert!(atomic_batch_ok.is_some());

    // Case B: One user is missing
    let batch_ids_missing = vec![1, 404, 3];
    let results_missing: Vec<Option<User>> =
        batch_ids_missing.into_iter().map(fetch_user).collect();
    println!("\nRaw Results (Missing): {:?}", results_missing);

    // Manual sequence: One None causes the whole batch to be None
    let atomic_batch_missing: Option<Vec<User>> = sequence_option(results_missing);

    println!("Atomic Batch (Missing): {:?}", atomic_batch_missing);
    assert_eq!(atomic_batch_missing, None);

    println!("\n--- 2. Fail-Fast Validation (Result) ---");

    // Scenario: Validating a list of transactions.
    let validate_tx = |amount: i32| -> Result<i32, String> {
        if amount < 0 {
            Err(format!("Negative amount: {}", amount))
        } else {
            Ok(amount)
        }
    };

    // Case A: All valid
    let tx_batch_ok = vec![100, 200, 50];
    let validation_results_ok: Vec<Result<i32, String>> =
        tx_batch_ok.into_iter().map(validate_tx).collect();

    let block_ok: Result<Vec<i32>, String> = sequence_result(validation_results_ok);

    println!("Block Validation (OK): {:?}", block_ok);
    assert!(block_ok.is_ok());

    // Case B: One invalid
    let tx_batch_invalid = vec![100, -50, 200];
    let validation_results_invalid: Vec<Result<i32, String>> =
        tx_batch_invalid.into_iter().map(validate_tx).collect();

    // The first Err aborts the sequence and is returned
    let block_invalid: Result<Vec<i32>, String> = sequence_result(validation_results_invalid);

    println!("Block Validation (Invalid): {:?}", block_invalid);
    assert!(block_invalid.is_err());

    println!("\n--- 3. Demonstrating OptionWitness Functor (fmap) ---");

    // Show that the constraint system works with our HKT traits
    let opt_val: Option<i32> = Some(10);
    let doubled: Option<i32> = OptionWitness::fmap(opt_val, |x| x * 2);
    println!("Original: Some(10), Doubled: {:?}", doubled);
    assert_eq!(doubled, Some(20));
}

/// Manual sequence for Option: Vec<Option<T>> -> Option<Vec<T>>
fn sequence_option<T>(opts: Vec<Option<T>>) -> Option<Vec<T>> {
    let mut result = Vec::with_capacity(opts.len());
    for opt in opts {
        match opt {
            Some(v) => result.push(v),
            None => return None,
        }
    }
    Some(result)
}

/// Manual sequence for Result: Vec<Result<T, E>> -> Result<Vec<T>, E>
fn sequence_result<T, E>(results: Vec<Result<T, E>>) -> Result<Vec<T>, E> {
    let mut collected = Vec::with_capacity(results.len());
    for result in results {
        match result {
            Ok(v) => collected.push(v),
            Err(e) => return Err(e),
        }
    }
    Ok(collected)
}

#[derive(Debug, Clone, PartialEq)]
struct User {
    id: u32,
    name: String,
}
