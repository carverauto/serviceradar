/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_data_structures::window_type;

fn main() {
    // Size refers to the maximum number of elements the sliding window can store
    const SIZE: usize = 4;
    // Multiplier to calculate capacity as size * multiple
    const MULT: usize = 3; // Capacity: 4 * 3 = 12

    // Create a sliding window for f64 values
    let mut window = window_type::new_with_vector_storage::<f64>(SIZE, MULT);

    // Push some values
    window.push(1.0);
    window.push(2.0);
    window.push(3.0);
    window.push(4.0);

    // Window is now filled
    assert!(window.filled());

    // Get values in different formats
    println!("As vector: {:?}", window.slice());
    // Get first and last values
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());

    // Push more values - older values will be dropped
    window.push(5.0);
    window.push(6.0);

    println!("After pushing more values:");
    println!("As vector: {:?}", window.slice());
    // Get first and last values
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());
}
