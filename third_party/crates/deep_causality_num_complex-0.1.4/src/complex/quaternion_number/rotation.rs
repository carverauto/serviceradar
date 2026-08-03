/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Quaternion, RealField, Rotation};

impl<T: RealField> Rotation<T> for Quaternion<T> {
    fn rotate_x(&self, angle: T) -> Self {
        // Rotor R = cos(t/2) + sin(t/2) * i
        let half = angle / (T::one() + T::one());
        let c = half.cos();
        let s = half.sin();

        let rotor = Quaternion {
            w: c,
            x: s,
            y: T::zero(),
            z: T::zero(),
        };
        // Apply: q' = R * q
        rotor * *self
    }

    fn rotate_y(&self, angle: T) -> Self {
        let half = angle / (T::one() + T::one());
        let c = half.cos();
        let s = half.sin();
        let rotor = Quaternion {
            w: c,
            x: T::zero(),
            y: s,
            z: T::zero(),
        };
        rotor * *self
    }

    fn rotate_z(&self, angle: T) -> Self {
        let half = angle / (T::one() + T::one());
        let c = half.cos();
        let s = half.sin();
        let rotor = Quaternion {
            w: c,
            x: T::zero(),
            y: T::zero(),
            z: s,
        };
        rotor * *self
    }

    fn global_phase(&self, _angle: T) -> Self {
        // Quaternions don't support global complex phase e^{i theta}
        // in the standard 4D definition (requires Complex Quaternions).
        // Returning self is the safe "Real" behavior.
        *self
    }
}
