/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! MatrixRep trait implementation for CausalMultiVector.
//!
//! Enables conversion between coefficient representation and matrix representation
//! for Clifford algebra operations.

use crate::CausalMultiVector;
use crate::types::multifield::ops::gamma;
use deep_causality_algebra::Field;
use deep_causality_metric::Metric;
use deep_causality_tensor::{CausalTensor, Tensor};
use std::ops::Neg;

impl<T> CausalMultiVector<T>
where
    T: Field + Copy + Default + PartialOrd + Neg<Output = T>,
{
    /// Converts this multivector to matrix representation.
    pub fn to_matrix(&self) -> CausalTensor<T> {
        let n = self.metric.dimension();
        let num_blades = 1usize << n;
        let matrix_dim = 1usize << n.div_ceil(2);

        // Get coefficients as a tensor [num_blades, 1, 1]
        let coeffs_tensor = CausalTensor::from_slice(&self.data, &[num_blades, 1, 1]);

        // Get batch of basis gammas [num_blades, matrix_dim, matrix_dim]
        let basis_gammas = gamma::get_basis_gammas::<T>(&self.metric);

        // Multiply: Coeffs * Basis (broadcasting handles [B,1,1] * [B,D,D])
        let scaled = &coeffs_tensor * &basis_gammas;

        // Sum along the batch axis (0) to get result matrix [matrix_dim, matrix_dim]
        let sum = scaled.sum_axes(&[0]).unwrap();

        // Reshape result to [D, D]
        sum.reshape(&[matrix_dim, matrix_dim])
            .expect("reshape failed")
    }

    /// Converts Matrix Representation back to coefficients.
    ///
    /// Uses trace projection: aᵢ = Tr(M · Γᵢ†) / matrix_dim
    pub fn from_matrix(matrix: CausalTensor<T>, metric: Metric) -> Self {
        let n = metric.dimension();
        let matrix_dim = 1usize << n.div_ceil(2);

        // Get dual basis gammas [num_blades, D, D]
        let dual_basis = gamma::get_dual_basis_gammas::<T>(&metric);

        // Prepare matrix for batch contraction [1, D, D]
        let matrix_batch = matrix
            .reshape(&[1, matrix_dim, matrix_dim])
            .expect("reshape failed");

        // Trace projection via element-wise product and sum
        let product = &matrix_batch * &dual_basis;

        // Sum along R and C axes (1, 2) to get [num_blades]
        let sum = product.sum_axes(&[1, 2]).unwrap();

        // Normalization: divide by matrix_dim
        let mut dim_t = T::zero();
        for _ in 0..matrix_dim {
            dim_t = dim_t + T::one();
        }

        let normalized = if !dim_t.is_zero() {
            let scale = CausalTensor::<T>::from_shape_fn(&[1], |_| T::one() / dim_t);
            &sum * &scale
        } else {
            sum
        };

        let coeffs = normalized.to_vec();
        Self::unchecked(coeffs, metric)
    }

    /// Gets the gamma matrix for a specific blade index.
    pub fn get_gamma_matrix(&self, blade_idx: usize) -> CausalTensor<T> {
        let n = self.metric.dimension();
        let matrix_dim = 1usize << n.div_ceil(2);

        // Get basis gammas
        let basis_gammas = gamma::get_basis_gammas::<T>(&self.metric);

        // Use Tensor::slice(axis, index) to get blade at blade_idx
        let slice = basis_gammas.slice(0, blade_idx).expect("slice failed");

        slice
            .reshape(&[matrix_dim, matrix_dim])
            .expect("reshape failed")
    }
}
