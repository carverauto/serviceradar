/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{PointIndex, Storage};

// T Type
// W Width
// H Height
// D Depth
// C Chronos (Time) since T was already taken for Type T
/// Implements `Storage` for 4D arrays `[[[[T; W]; H]; D]; C]`
/// indexed along X (width), Y (height), Z (depth), and T (time) axes.
///
/// Note: The last dimension `C` represents **chronos** (time),
/// since `T` is used for the value type.
impl<T, const W: usize, const H: usize, const D: usize, const C: usize> Storage<T>
    for [[[[T; W]; H]; D]; C]
where
    T: Copy,
    [[[[T; W]; H]; D]; C]: Sized,
{
    fn get(&self, p: PointIndex) -> &T {
        &self[p.t][p.z][p.y][p.x]
    }

    fn set(&mut self, p: PointIndex, elem: T) {
        self[p.t][p.z][p.y][p.x] = elem
    }

    fn height(&self) -> Option<&usize> {
        Some(&H)
    }

    fn depth(&self) -> Option<&usize> {
        Some(&D)
    }

    fn time(&self) -> Option<&usize> {
        Some(&C)
    }

    fn width(&self) -> Option<&usize> {
        Some(&W)
    }
}
