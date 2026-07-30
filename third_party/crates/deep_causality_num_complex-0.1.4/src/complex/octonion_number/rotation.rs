/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{DivisionAlgebra, Octonion, RealField, Rotation};

impl<T: RealField> Rotation<T> for Octonion<T> {
    /// Rotates the Octonion around the $e_1$ axis.
    /// $R = \cos(\theta/2) + e_1 \sin(\theta/2)$
    fn rotate_x(&self, angle: T) -> Self {
        let two = T::one() + T::one();
        let half_theta = angle / two;

        let c = half_theta.cos();
        let s = half_theta.sin();

        // Construct Rotor R = cos + e1 * sin
        let rotor = Octonion {
            s: c,
            e1: s,
            e2: T::zero(),
            e3: T::zero(),
            e4: T::zero(),
            e5: T::zero(),
            e6: T::zero(),
            e7: T::zero(),
        };

        // Apply Rotation: (R * v) * R*
        // Note: Octonions are Non-Associative, so grouping matters.
        // However, they are Alternative, and this conjugation is stable.
        let rotor_conj = rotor.conjugate();

        (rotor * *self) * rotor_conj
    }

    /// Rotates the Octonion around the $e_2$ axis.
    /// $R = \cos(\theta/2) + e_2 \sin(\theta/2)$
    fn rotate_y(&self, angle: T) -> Self {
        let two = T::one() + T::one();
        let half_theta = angle / two;

        let c = half_theta.cos();
        let s = half_theta.sin();

        let rotor = Octonion {
            s: c,
            e1: T::zero(),
            e2: s,
            e3: T::zero(),
            e4: T::zero(),
            e5: T::zero(),
            e6: T::zero(),
            e7: T::zero(),
        };

        let rotor_conj = rotor.conjugate();
        (rotor * *self) * rotor_conj
    }

    /// Rotates the Octonion around the $e_3$ axis.
    /// $R = \cos(\theta/2) + e_3 \sin(\theta/2)$
    fn rotate_z(&self, angle: T) -> Self {
        let two = T::one() + T::one();
        let half_theta = angle / two;

        let c = half_theta.cos();
        let s = half_theta.sin();

        let rotor = Octonion {
            s: c,
            e1: T::zero(),
            e2: T::zero(),
            e3: s,
            e4: T::zero(),
            e5: T::zero(),
            e6: T::zero(),
            e7: T::zero(),
        };

        let rotor_conj = rotor.conjugate();
        (rotor * *self) * rotor_conj
    }

    /// Global Phase Shift.
    ///
    /// Octonions are a **Real** algebra. They do not have a central imaginary unit $i$
    /// that commutes with everything (unlike Complex numbers).
    /// Therefore, a "Global Phase" $e^{i\phi}$ is not well-defined in standard Octonion arithmetic
    /// without picking a specific preferred axis (which effectively becomes a rotation).
    ///
    /// To maintain mathematical strictness, this is an Identity operation.
    fn global_phase(&self, _angle: T) -> Self {
        *self
    }
}
