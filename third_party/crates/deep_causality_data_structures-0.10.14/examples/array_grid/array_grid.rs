/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use deep_causality_data_structures::{ArrayGrid, ArrayType, PointIndex};

// Consts dimensions requires for const generic parameters
// Use these to check whether your PointIndex stays within the Array boundaries.
const WIDTH: usize = 5;
const HEIGHT: usize = 5;
const DEPTH: usize = 5;
const TIME: usize = 5;

// Util function that helps with type inference.
fn get_array_grid<T: Copy + Default>(
    array_type: ArrayType,
) -> ArrayGrid<T, WIDTH, HEIGHT, DEPTH, TIME> {
    ArrayGrid::new(array_type)
}

pub fn main() {
    println!("\n1. Testing 1D Array:");
    // Make a simple 1D Array of type usize
    let array_type = ArrayType::Array1D;
    let ag = get_array_grid(array_type);

    // Create a 1D PointIndex
    let p = PointIndex::new1d(1);

    // Store a usize with the point index
    ag.set(p, 42);

    // Get the usize for the point index
    let res = ag.get(p);
    println!("Value at 1D point index {p}: {res}");
    assert_eq!(res, 42);

    println!("\n2. Testing 3D Array:");
    // Make a 3D array aka matrix over x,y,z that stores u64
    let array_type = ArrayType::Array3D;
    let ag = get_array_grid(array_type);

    // Create a new 3D point index
    let p = PointIndex::new3d(1, 2, 3);

    // Set a u64 value
    ag.set(p, 3);

    // Get the value at the point index
    let res = ag.get(p);
    println!("Value at 3D point index {p}: {res}");
    assert_eq!(res, 3);

    println!("\n3. Testing 4D Array with Custom Struct:");
    // ArrayGrid requires Copy + Default to store MyStuct
    #[derive(Debug, Default, Copy, Clone)]
    struct MyStruct {
        number: usize,
        mod_five: bool,
    }

    // Make a 4D array aka matrix over x,y,z that stores My struct
    let array_type = ArrayType::Array4D;
    let ag: ArrayGrid<MyStruct, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);

    // Create a new 4D point index where only time varies
    let idx_t0 = PointIndex::new4d(1, 1, 1, 0);
    let idx_t1 = PointIndex::new4d(1, 1, 1, 1);
    let idx_t2 = PointIndex::new4d(1, 1, 1, 2);

    // Create some data for each index
    let my_struct_t0 = MyStruct {
        number: 23,
        mod_five: false,
    };
    let my_struct_t1 = MyStruct {
        number: 24,
        mod_five: false,
    };
    let my_struct_t2 = MyStruct {
        number: 25,
        mod_five: true,
    };

    // Store data
    ag.set(idx_t0, my_struct_t0);
    ag.set(idx_t1, my_struct_t1);
    ag.set(idx_t2, my_struct_t2);

    // Get data at each time point
    println!("Values at fixed position (1,1,1) over time:");
    println!("t=0: {:?}", ag.get(idx_t0));
    println!("t=1: {:?}", ag.get(idx_t1));
    println!("t=2: {:?}", ag.get(idx_t2));

    // Verify results
    let res = ag.get(idx_t2);
    assert_eq!(res.number, 25);
    assert!(res.mod_five);

    println!("\nAll tests passed successfully!");
}
