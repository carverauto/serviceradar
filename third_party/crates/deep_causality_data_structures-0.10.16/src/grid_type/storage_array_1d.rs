/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{PointIndex, Storage};

// T Type
// H Height
/// Implements `Storage` for 1D arrays `[T; H]` indexed along the X-axis only.
impl<T, const H: usize> Storage<T> for [T; H]
where
    T: Copy,
    [T; H]: Sized,
{
    fn get(&self, p: PointIndex) -> &T {
        &self[p.x]
    }

    fn set(&mut self, p: PointIndex, elem: T) {
        self[p.x] = elem
    }

    fn height(&self) -> Option<&usize> {
        Some(&H)
    }
}
