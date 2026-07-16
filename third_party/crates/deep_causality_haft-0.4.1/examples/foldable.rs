/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{Foldable, VecWitness};

// ============================================================================
// Domain: E-Commerce Order Processing
// ============================================================================

fn main() {
    println!("=== DeepCausality HKT: Foldable Pattern ===\n");

    // ------------------------------------------------------------------------
    // Foldable: Aggregation
    //
    // ENGINEERING VALUE:
    // You have a collection of items (Vec, List, Tree) and you need to reduce them
    // to a single value (Sum, Max, Average, Concatenation).
    //
    // Foldable abstracts the "Loop and Accumulate" pattern.
    // ------------------------------------------------------------------------
    println!("--- Order Aggregation ---");

    let orders = vec![
        OrderItem {
            id: "A".to_string(),
            price: 10.0,
            quantity: 2,
        },
        OrderItem {
            id: "B".to_string(),
            price: 5.0,
            quantity: 10,
        },
        OrderItem {
            id: "C".to_string(),
            price: 100.0,
            quantity: 1,
        },
    ];

    // Calculate Total Revenue
    let total_revenue = VecWitness::fold(orders.clone(), 0.0, |acc, item| {
        acc + (item.price * item.quantity as f64)
    });
    println!("Total Revenue: ${:.2}", total_revenue);
    assert_eq!(total_revenue, 170.0);

    // Calculate Total Items
    let total_items = VecWitness::fold(orders, 0, |acc, item| acc + item.quantity);
    println!("Total Items:   {}", total_items);
    assert_eq!(total_items, 13);
}

#[derive(Debug, Clone, PartialEq)]
struct OrderItem {
    id: String,
    price: f64,
    quantity: u32,
}
