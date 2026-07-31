/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{PointIndex, Storage};

// T Type
// W Width
// H Height
// D Depth
/// Implements `Storage` for 3D arrays `[[[T; W]; H]; D]`
/// indexed along X (width), Y (height), and Z (depth) axes.
impl<T, const W: usize, const H: usize, const D: usize> Storage<T> for [[[T; W]; H]; D]
where
    T: Copy,
    [[[T; W]; H]; D]: Sized,
{
    fn get(&self, p: PointIndex) -> &T {
        &self[p.z][p.y][p.x]
    }

    fn set(&mut self, p: PointIndex, elem: T) {
        self[p.z][p.y][p.x] = elem
    }

    fn height(&self) -> Option<&usize> {
        Some(&H)
    }

    fn depth(&self) -> Option<&usize> {
        Some(&D)
    }

    fn width(&self) -> Option<&usize> {
        Some(&W)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_3d_array_indexing_with_distinct_dimensions() {
        // Use distinct dimensions to reveal the bug
        const WIDTH: usize = 3; // X-axis
        const HEIGHT: usize = 4; // Y-axis
        const DEPTH: usize = 2; // Z-axis

        let mut storage: [[[i32; WIDTH]; HEIGHT]; DEPTH] = [[[0; WIDTH]; HEIGHT]; DEPTH];

        // Raw array structure: [[[T; W]; H]; D]
        // This means: storage[depth_idx][height_idx][width_idx]

        // Set a value at a specific location using raw array indexing
        // depth=1, height=2, width=1
        storage[1][2][1] = 99;

        // Now access the same location using Storage trait
        // According to PointIndex semantics:
        // - x represents width (X-axis)
        // - y represents height (Y-axis)
        // - z represents depth (Z-axis)
        let point = PointIndex::new3d(
            1, // x = width = 1
            2, // y = height = 2
            1, // z = depth = 1
        );

        // This should retrieve the value we just set (99)
        // Use fully qualified syntax to avoid ambiguity with 1D/2D implementations
        let retrieved = *<[[[i32; WIDTH]; HEIGHT]; DEPTH] as Storage<i32>>::get(&storage, point);

        assert_eq!(
            retrieved, 99,
            "Expected to retrieve 99 from position (width=1, height=2, depth=1), but got {}",
            retrieved
        );
    }

    #[test]
    fn test_3d_array_set_and_get_consistency() {
        const WIDTH: usize = 3;
        const HEIGHT: usize = 4;
        const DEPTH: usize = 2;

        let mut storage: [[[i32; WIDTH]; HEIGHT]; DEPTH] = [[[0; WIDTH]; HEIGHT]; DEPTH];

        // Test a specific non-symmetric position
        let point = PointIndex::new3d(2, 3, 1); // x=2, y=3, z=1
        let test_value = 42;

        // Set using Storage trait
        <[[[i32; WIDTH]; HEIGHT]; DEPTH] as Storage<i32>>::set(&mut storage, point, test_value);

        // Get using Storage trait
        let retrieved = *<[[[i32; WIDTH]; HEIGHT]; DEPTH] as Storage<i32>>::get(&storage, point);

        // This should work, but let's verify what raw position was actually set
        // Expected: storage[z=1][y=3][x=2] = storage[1][3][2]
        let raw_value = storage[1][3][2];

        assert_eq!(
            retrieved, test_value,
            "Storage trait get/set should be consistent"
        );

        assert_eq!(
            raw_value, test_value,
            "Value should be at storage[depth=1][height=3][width=2], but it's not there"
        );
    }
}
