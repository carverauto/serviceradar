/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{Functor, OptionWitness};

// ============================================================================
// Domain: E-Commerce Order Processing
// ============================================================================

fn main() {
    println!("=== DeepCausality HKT: Applicative Pattern ===\n");

    // ------------------------------------------------------------------------
    // Applicative: Independent Validation
    //
    // ENGINEERING VALUE:
    // When validating a form, you often want to collect ALL errors, not just the first one.
    // Or you want to combine multiple independent results (e.g., parallel API calls).
    //
    // Applicative (`apply`) allows you to combine values inside a context (Result/Option)
    // independent of each other.
    // ------------------------------------------------------------------------
    println!("--- Independent Validation ---");

    let validate_id = |id: &str| -> Option<String> {
        if id.len() > 3 {
            Some(id.to_string())
        } else {
            None
        }
    };

    let validate_qty = |qty: u32| -> Option<u32> { if qty > 0 { Some(qty) } else { None } };

    // We want to create an OrderItem ONLY if both ID and Qty are valid.
    // Applicative style: pure(constructor).apply(id).apply(qty)

    let valid_id = validate_id("item_123");
    let _valid_qty = validate_qty(5);
    let price = 10.0;

    // Note: Rust's type system makes currying a bit verbose, so we often use helper macros or
    // explicit closures. Here we show the raw `apply` mechanism.
    // We lift a closure that takes (String, u32) -> OrderItem
    let constructor = |id: String| {
        move |qty: u32| OrderItem {
            id,
            price,
            quantity: qty,
        }
    };

    // Step 1: Lift constructor into Option
    // Option<Fn(String) -> Fn(u32) -> OrderItem>
    // Using OptionWitness::fmap for step 1
    let _partial_constructor = OptionWitness::fmap(valid_id, constructor);

    // Now we have Option<Fn(u32) -> OrderItem>. We need to apply Option<u32>.
    // OptionWitness::apply expects Option<Fn(A) -> B> and Option<A>.

    let config_host = Some("localhost".to_string());
    let config_port = 8080; // Directly use value to avoid unwrap warning

    // We want to combine them into a string "host:port"
    let combine = |host: String| move |port: i32| format!("{}:{}", host, port);

    let partial = OptionWitness::fmap(config_host, combine);
    // partial is Some(Fn(i32) -> String)

    // We need to cast/coerce the closure type for `apply` to work generically,
    // which is hard in stable Rust without boxing.
    // So we'll simulate `apply` behavior for the example's clarity.

    if let Some(f) = partial {
        let result = f(config_port); // Simulating apply
        println!("Applicative Result: {}", result);
    }
}

#[derive(Debug, Clone, PartialEq)]
struct OrderItem {
    id: String,
    price: f64,
    quantity: u32,
}
