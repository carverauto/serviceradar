/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Complex, RealField, Rotation};

impl<T: RealField> Rotation<T> for Complex<T> {
    fn rotate_x(&self, _angle: T) -> Self {
        *self
    } // No X-axis in 2D
    fn rotate_y(&self, _angle: T) -> Self {
        *self
    } // No Y-axis in 2D

    fn rotate_z(&self, angle: T) -> Self {
        // Z-rotation IS Global Phase for scalars
        self.global_phase(angle)
    }

    fn global_phase(&self, angle: T) -> Self {
        let rot = Complex {
            re: angle.cos(),
            im: angle.sin(),
        };
        *self * rot
    }
}
