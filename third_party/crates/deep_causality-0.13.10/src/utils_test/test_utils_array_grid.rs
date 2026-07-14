/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use deep_causality_data_structures::{ArrayGrid, ArrayType, PointIndex};

pub const HEIGHT: usize = 5;
// set all unused dimensions to 0 to save some memory.
pub const WIDTH: usize = 5;
pub const DEPTH: usize = 5;
pub const TIME: usize = 5;

pub type AdjustmentData = ArrayGrid<i32, WIDTH, HEIGHT, DEPTH, TIME>;

pub fn get_1d_array_grid(val: i32) -> AdjustmentData {
    let array_type = ArrayType::Array1D;
    let ag: ArrayGrid<i32, WIDTH, HEIGHT, DEPTH, TIME> = ArrayGrid::new(array_type);

    // Create a 1D PointIndex
    let p = PointIndex::new1d(0);

    // Store an i32 with th position of the point index
    ag.set(p, val);

    ag
}
