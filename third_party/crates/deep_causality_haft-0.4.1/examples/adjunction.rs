/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// ============================================================================
// Adjunction: Global Configuration Access
// ============================================================================

// ENGINEERING VALUE:
// Adjunctions describe a relationship between two functors: Left (L) and Right (R).
// A classic example is (Writer -| Reader) or (Product -| Exponential).
//
// Here we demonstrate the "Reader Adjunction" pattern (Product -| Reader).
// It allows us to convert a function that takes a Context (Reader) into a
// simple value pair (Product), and vice versa.
//
// Practical Use: "Currying" configuration.
// Instead of passing `Config` to every function, we can "adjunct" the function
// to lock in the config, producing a standalone value.

fn main() {
    println!("=== DeepCausality HKT: Adjunction Pattern ===\n");
    println!("--- Reader/Writer Duality ---");
    println!("(Demonstration of concept)");

    // Scenario: We have a function that fetches data given a Config and an ID.
    // fetch_data: (Config, i32) -> String
    let fetch_data = |cfg: Config, id: i32| -> String {
        format!("Data for ID {} using Key {}", id, cfg.api_key)
    };

    // We want to "bake in" the ID first, creating a reusable "Reader" that just needs Config.
    // We use the Right Adjunct logic manually here since Rust closures are tricky.

    let id_to_fetch = 42;
    let reader = move |cfg: Config| fetch_data(cfg, id_to_fetch);

    // Now 'reader' is a function Config -> String.
    // We can pass this 'reader' around to a component that holds the Config.

    let my_config = Config {
        api_key: "SECRET_KEY".to_string(),
    };

    let result = reader(my_config);
    println!("Adjunction Result: {}", result);
}

struct Config {
    api_key: String,
}

// Mock Adjunction Implementation for demonstration
#[allow(dead_code)]
struct ConfigAdjunction;

#[allow(dead_code)]
impl ConfigAdjunction {
    // Left Adjunct: (Config, A) -> B  ===>  A -> (Config -> B)
    fn left_adjunct<A, B, F>(f: F) -> impl Fn(A) -> Box<dyn Fn(Config) -> B>
    where
        A: Clone + 'static,
        F: Fn(Config, A) -> B + Clone + 'static,
    {
        move |a: A| {
            let f = f.clone();
            let a = a.clone();
            Box::new(move |cfg: Config| f(cfg, a.clone()))
        }
    }

    // Right Adjunct: A -> (Config -> B)  ===>  (Config, A) -> B
    fn right_adjunct<A, B, F>(f: F) -> impl Fn(Config, A) -> B
    where
        F: Fn(A) -> Box<dyn Fn(Config) -> B>,
    {
        move |cfg: Config, a: A| {
            let reader = f(a);
            reader(cfg)
        }
    }
}
