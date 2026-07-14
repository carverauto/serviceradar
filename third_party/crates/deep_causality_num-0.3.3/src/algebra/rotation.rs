/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::RealField;

/// A trait for types that can be rotated in 3D space (or the Bloch Sphere).
///
/// * T: The scalar type (angle).
pub trait Rotation<T: RealField> {
    /// Rotation around the X-axis.
    /// Quaternions: Axis `i`. Quantum: Pauli X.
    fn rotate_x(&self, angle: T) -> Self;

    /// Rotation around the Y-axis.
    /// Quaternions: Axis `j`. Quantum: Pauli Y.
    fn rotate_y(&self, angle: T) -> Self;

    /// Rotation around the Z-axis (Phase).
    /// Quaternions: Axis `k`. Quantum: Pauli Z.
    fn rotate_z(&self, angle: T) -> Self;

    /// Global Phase Shift.
    /// $P(\phi) = e^{i\phi}$.
    fn global_phase(&self, angle: T) -> Self;
}
