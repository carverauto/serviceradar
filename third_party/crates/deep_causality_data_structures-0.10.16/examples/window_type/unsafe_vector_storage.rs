/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use dcl_data_structures::window_type;

fn main() {
    // Size refers to the maximum number of elements the sliding window can store
    const SIZE: usize = 4;
    // Multiplier to calculate capacity as size * multiple
    const MULT: usize = 3; // Capacity: 4 * 3 = 12

    // Create a sliding window with unsafe vector storage for better performance
    let mut window = window_type::new_with_unsafe_vector_storage::<i32>(SIZE, MULT);

    // Push some values
    window.push(-10);
    window.push(-20);
    window.push(-30);
    window.push(-40);

    // Window is now filled
    assert!(window.filled());

    // Get values in different formats
    println!("As vector: {:?}", window.slice());
    // Get first and last values
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());

    // Push more values - older values will be dropped
    window.push(-50);
    window.push(-60);

    println!("After pushing more values:");
    println!("As vector: {:?}", window.slice());
    // Get first and last values
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());
}
