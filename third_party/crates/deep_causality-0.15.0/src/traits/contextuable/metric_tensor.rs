/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Trait for exposing and modifying a local 4×4 spacetime metric tensor.
///
/// This trait defines both **read** and **write** access to a spacetime metric `gᵤᵥ`,
/// typically used for computing intervals and geodesics. By including a mutation method,
/// the curvature at a point can be dynamically updated in response to external fields,
/// symbolic programs, or causal evolution.
///
/// # Convention
/// - Tensor is 4×4, with ordering `[t, x, y, z]`
/// - Signature is (− + + +)
/// - Symmetry (`gᵤᵥ = gᵥᵤ`) must be preserved by caller
pub trait MetricTensor4D {
    /// Returns the current local metric tensor `gᵤᵥ`.
    fn metric_tensor(&self) -> [[f64; 4]; 4];

    /// Updates the internal metric tensor to a new 4×4 matrix.
    ///
    /// # Safety
    /// - Caller must ensure the matrix is symmetric
    /// - In curved models, tensor should be valid under coordinate charts
    fn update_metric_tensor(&mut self, new_metric: [[f64; 4]; 4]);
}
