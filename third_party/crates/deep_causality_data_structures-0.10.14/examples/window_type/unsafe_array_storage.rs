/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// Example demonstrating the usage of window_type with array storage
use dcl_data_structures::window_type;

fn main() {
    // Create a window with size 5 and capacity 10 using the array storage backend
    let mut window = window_type::new_with_array_storage::<i32, 5, 10>();

    // Push some values
    for i in 0..7 {
        window.push(i);
    }

    // Get the current window contents
    let slice = window.slice();
    println!("Window contents: {:?}", slice);

    // Access first and last elements
    if let Ok(first) = window.first() {
        println!("First element: {}", first);
    }

    if let Ok(last) = window.last() {
        println!("Last element: {}", last);
    }
}
