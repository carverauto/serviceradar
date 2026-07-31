/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{
    BTreeMapWitness, BoxWitness, Functor, HKT, HashMapWitness, LinkedListWitness, OptionWitness,
    ResultWitness, Satisfies, VecDequeWitness, VecWitness,
};
use std::collections::{BTreeMap, HashMap, LinkedList, VecDeque};

// ============================================================================
// Domain Logic: Data Anonymization
// ============================================================================

// A generic function that applies a transformation to ANY container that implements Functor.
//
// ENGINEERING VALUE:
// In a large system, data is stored in various structures (Vec, HashMap, Option, etc.).
// You often need to apply the SAME business logic (e.g., "Anonymize PII") to all of them.
//
// Instead of writing `anonymize_vec`, `anonymize_map`, `anonymize_option`, you write
// ONE generic function `process_batch` that works on ALL of them.
// This drastically reduces code duplication and ensures consistent behavior.
fn process_batch<F, T, U>(container: F::Type<T>, transform: impl FnMut(T) -> U) -> F::Type<U>
where
    F: Functor<F> + HKT,
    T: Satisfies<F::Constraint>,
    U: Satisfies<F::Constraint>,
{
    F::fmap(container, transform)
}

fn main() {
    println!("=== DeepCausality HKT: Batch Data Processing ===\n");

    // The Transformation: Masking sensitive IDs
    // Logic: If ID > 1000, mask it. Otherwise keep it.
    let anonymize_id = |id: i32| -> String {
        if id > 1000 {
            "****".to_string()
        } else {
            id.to_string()
        }
    };

    println!("--- 1. Processing Linear Collections (Vec, List, Deque) ---");

    // Scenario: User IDs stored in a simple list
    let user_ids_vec = vec![101, 5000, 42, 9999];
    println!("Original Vec: {:?}", user_ids_vec);

    // Apply transformation using the generic processor
    let masked_vec = process_batch::<VecWitness, _, _>(user_ids_vec, anonymize_id);
    println!("Masked Vec:   {:?}", masked_vec);
    assert_eq!(masked_vec, vec!["101", "****", "42", "****"]);

    // Works identically for LinkedList
    let user_ids_list = LinkedList::from([101, 5000]);
    let masked_list = process_batch::<LinkedListWitness, _, _>(user_ids_list, anonymize_id);
    println!("Masked List:  {:?}", masked_list);

    // Works identically for VecDeque
    let user_ids_deque = VecDeque::from([9999, 42]);
    let masked_deque = process_batch::<VecDequeWitness, _, _>(user_ids_deque, anonymize_id);
    println!("Masked Deque: {:?}", masked_deque);

    println!("\n--- 2. Processing Key-Value Stores (HashMap, BTreeMap) ---");

    // Scenario: User IDs indexed by Session ID
    // Note: Functor for Map types typically maps over the VALUE, preserving the KEY.
    let mut session_map = HashMap::new();
    session_map.insert("session_1", 101);
    session_map.insert("session_2", 5000);

    println!("Original HashMap: {:?}", session_map);

    let masked_map = process_batch::<HashMapWitness<&str>, _, _>(session_map, anonymize_id);
    println!("Masked HashMap:   {:?}", masked_map);

    // Works identically for BTreeMap
    let mut ordered_map = BTreeMap::new();
    ordered_map.insert(1, 5000);
    ordered_map.insert(2, 101);

    let masked_btree = process_batch::<BTreeMapWitness<i32>, _, _>(ordered_map, anonymize_id);
    println!("Masked BTreeMap:  {:?}", masked_btree);

    println!("\n--- 3. Processing Contexts (Option, Result, Box) ---");

    // Scenario: A single User ID that might be missing (Option)
    let maybe_user = Some(5000);
    let masked_opt = process_batch::<OptionWitness, _, _>(maybe_user, anonymize_id);
    println!("Masked Option: {:?}", masked_opt);
    assert_eq!(masked_opt, Some("****".to_string()));

    // Scenario: A User ID fetch result
    let fetch_result: Result<i32, &str> = Ok(5000);
    let masked_res = process_batch::<ResultWitness<&str>, _, _>(fetch_result, anonymize_id);
    println!("Masked Result: {:?}", masked_res);
    assert_eq!(masked_res, Ok("****".to_string()));

    // Scenario: A heap-allocated ID
    let boxed_id = Box::new(5000);
    let masked_box = process_batch::<BoxWitness, _, _>(boxed_id, anonymize_id);
    println!("Masked Box:    {:?}", masked_box);
    assert_eq!(masked_box, Box::new("****".to_string()));
}
