/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_data_structures::window_type;

fn main() {
    // Size refers to the maximum number of elements the sliding window can store
    const SIZE: usize = 4;
    // Capacity refers to the maximum number of elements before a rewind occurs
    const CAPACITY: usize = 12;

    // Create a new sliding window with array storage
    let mut window = window_type::new_with_array_storage::<i32, SIZE, CAPACITY>();

    // Push some values
    window.push(10);
    window.push(20);
    window.push(30);
    window.push(40);

    // Window is now filled
    assert!(window.filled());

    // Get values
    println!("As array: {:?}", window.slice());
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());

    // Push more values - older values will be dropped
    window.push(50);
    window.push(60);

    println!("After pushing more values:");
    println!("As array: {:?}", window.slice());
    println!("First value: {:?}", window.first());
    println!("Last value: {:?}", window.last());
}
