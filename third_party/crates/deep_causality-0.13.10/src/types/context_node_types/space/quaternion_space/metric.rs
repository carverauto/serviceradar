/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Metric, QuaternionSpace};

impl Metric<f64> for QuaternionSpace {
    /// Computes the Euclidean distance between two quaternions in 4D space.
    ///
    /// The quaternion is treated as a 4D vector in ℝ⁴ with components `[w, x, y, z]`.
    /// The standard Euclidean norm is applied:
    ///
    /// ```text
    /// d(q₁, q₂) = √[(w₁ - w₂)² + (x₁ - x₂)² + (y₁ - y₂)² + (z₁ - z₂)²]
    /// ```
    ///
    /// This implementation is appropriate when:
    /// - Quaternions are treated as general 4D points (not necessarily normalized).
    /// - You need straight-line (chordal) distance in Euclidean space.
    ///
    /// # Note
    /// If the quaternions represent **unit quaternions** (i.e., orientations), and you wish
    /// to compute the **angular distance** between them, consider overriding this method with:
    ///
    /// ```text
    /// let dot = q1.w * q2.w + q1.x * q2.x + q1.y * q2.y + q1.z * q2.z;
    /// let theta = 2.0 * dot.abs().acos(); // Angular distance in radians
    /// ```
    ///
    /// This version reflects the minimal rotation angle between two orientations on the unit hypersphere.
    fn distance(&self, other: &Self) -> f64 {
        let dw = self.w - other.w;
        let dx = self.x - other.x;
        let dy = self.y - other.y;
        let dz = self.z - other.z;

        (dw * dw + dx * dx + dy * dy + dz * dz).sqrt()
    }
}
