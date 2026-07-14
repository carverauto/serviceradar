/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::{BoxWitness, CoMonad, HKT};

// ============================================================================
// Domain Logic: System Evolution
// ============================================================================

fn main() {
    println!("=== DeepCausality HKT: Contextual Computation (Comonad) ===\n");

    // ------------------------------------------------------------------------
    // Concept: Comonad (The "Viewer" Pattern)
    //
    // ENGINEERING VALUE:
    // While Monads are about "Sequencing" (A -> M<B>), Comonads are about
    // "Contextual Computation" (W<A> -> B).
    //
    // You have a value in a context (e.g., a System Snapshot).
    // You want to compute a new value based on that *entire* context.
    // `extend` allows you to chain these context-aware computations.
    //
    // Scenario: Simulating a physical system cooling down.
    // Each step depends on the *current state* of the system.
    // ------------------------------------------------------------------------

    // Initial State: Hot and High Pressure
    let initial_state = Box::new(SystemState {
        temperature: 100.0,
        pressure: 50.0,
        step: 0,
    });
    println!("T0: Initial State: {:?}", initial_state);

    // 1. EXTRACT: Get the current value out of the context
    // Useful when you just need to read the sensor.
    let current_temp = BoxWitness::extract(&initial_state).temperature;
    println!("    Current Temp: {:.2}", current_temp);

    // 2. EXTEND: Evolve the system
    // We define a "Physics Rule": The system cools down and pressure drops.
    // This function takes the *entire* previous context (Box<State>) to compute the new State.
    let evolve_system = |w: &<BoxWitness as HKT>::Type<SystemState>| {
        let prev = &**w; // Access the value inside the context
        SystemState {
            temperature: prev.temperature * 0.90, // Cools by 10%
            pressure: prev.pressure * 0.95,       // Pressure drops by 5%
            step: prev.step + 1,
        }
    };

    // Apply the rule to get T1
    let state_t1 = BoxWitness::extend(&initial_state, evolve_system);
    println!("T1: Evolved State: {:?}", state_t1);

    // Apply the rule again to get T2
    // Note how we chain the evolution.
    let state_t2 = BoxWitness::extend(&state_t1, evolve_system);
    println!("T2: Evolved State: {:?}", state_t2);

    // 3. EXTEND: Context-Aware Analysis
    // We can also use `extend` to compute *derived* metrics that depend on the context.
    // Example: Calculate an "Alert Level" based on the state.
    let analyze_alert = |w: &<BoxWitness as HKT>::Type<SystemState>| {
        let state = &**w;
        if state.temperature > 85.0 {
            "CRITICAL"
        } else if state.temperature > 50.0 {
            "WARNING"
        } else {
            "NORMAL"
        }
    };

    // This transforms Box<SystemState> -> Box<&str> (The Alert Context)
    let alert_t0 = BoxWitness::extend(&initial_state, analyze_alert);
    let alert_t1 = BoxWitness::extend(&state_t1, analyze_alert);
    let alert_t2 = BoxWitness::extend(&state_t2, analyze_alert);

    println!("\n--- System Alert Log ---");
    println!("T0 Alert: {:?}", alert_t0);
    println!("T1 Alert: {:?}", alert_t1);
    println!("T2 Alert: {:?}", alert_t2);

    assert_eq!(*alert_t0, "CRITICAL"); // 100.0
    assert_eq!(*alert_t1, "CRITICAL"); // 90.0
    assert_eq!(*alert_t2, "WARNING"); // 81.0
}

#[derive(Debug, Clone, PartialEq)]
struct SystemState {
    temperature: f64,
    pressure: f64,
    step: u32,
}
