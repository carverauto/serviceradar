/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Differential operators for CausalMultiField.
//!
//! Implements curl, divergence, and gradient using central-difference stencils.

use crate::CausalMultiField;
use crate::types::multifield::ops::gamma;
use deep_causality_algebra::{Field, Ring};
use deep_causality_tensor::{CausalTensor, Tensor};

/// Axis enumeration for differential operators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    X = 0,
    Y = 1,
    Z = 2,
}

impl Axis {
    fn index(self) -> usize {
        self as usize
    }
}

impl<T> CausalMultiField<T>
where
    T: Field + Copy + Default + PartialOrd,
{
    /// Computes the curl: ∇ × F.
    ///
    /// Returns the grade-2 component of the gradient ∇F.
    pub fn curl(&self) -> Self
    where
        T: Ring + std::ops::Neg<Output = T>,
    {
        self.gradient().grade_project(2)
    }

    /// Computes the divergence: ∇ · F.
    ///
    /// Returns the scalar part (Grade 0) of the gradient ∇F.
    pub fn divergence(&self) -> Self
    where
        T: Ring + std::ops::Neg<Output = T>,
    {
        self.gradient().grade_project(0)
    }

    /// Computes the gradient: ∇F.
    ///
    /// Returns the full geometric derivative field (all grades).
    pub fn gradient(&self) -> Self
    where
        T: Ring + std::ops::Neg<Output = T>,
    {
        let dx = self.partial_derivative(Axis::X);
        let dy = self.partial_derivative(Axis::Y);
        let dz = self.partial_derivative(Axis::Z);

        self.construct_gradient(&dx, &dy, &dz)
    }

    /// Computes the partial derivative along a given axis.
    ///
    /// Uses central difference: ∂F/∂x ≈ (F[x+1] - F[x-1]) / (2dx)
    ///
    /// This implementation works on the flat data vector to avoid
    /// needing range-based slice operations.
    pub fn partial_derivative(&self, axis: Axis) -> CausalTensor<T>
    where
        T: Ring,
    {
        let axis_idx = axis.index();
        let n = self.shape[axis_idx];

        if n < 3 {
            return CausalTensor::<T>::zeros(self.data.shape());
        }

        let shape = self.data.shape().to_vec();
        let total_elements: usize = shape.iter().product();

        // Compute strides for indexing
        let mut strides = vec![1usize; shape.len()];
        for i in (0..shape.len() - 1).rev() {
            strides[i] = strides[i + 1] * shape[i + 1];
        }

        let data_vec = self.data.clone().to_vec();
        let axis_stride = strides[axis_idx];
        let two_dx = self.dx[axis_idx] + self.dx[axis_idx];
        let inv_two_dx = T::one() / two_dx;

        // Compute central differences
        let mut result_vec = vec![T::zero(); total_elements];

        for (flat_idx, val) in result_vec.iter_mut().enumerate() {
            // Convert flat index to multi-index
            let mut multi_idx = vec![0usize; shape.len()];
            let mut remainder = flat_idx;
            for d in 0..shape.len() {
                multi_idx[d] = remainder / strides[d];
                remainder %= strides[d];
            }

            let i = multi_idx[axis_idx];

            // Central difference: skip boundaries
            if i >= 1 && i < n - 1 {
                // Calculate indices for i+1 and i-1
                let forward_idx = flat_idx + axis_stride;
                let backward_idx = flat_idx - axis_stride;

                let diff = data_vec[forward_idx] - data_vec[backward_idx];
                *val = diff * inv_two_dx;
            }
            // Boundary points (i=0 or i=n-1) are left as zero
        }

        CausalTensor::from_slice(&result_vec, &shape)
    }

    /// Constructs gradient from partial derivatives.
    fn construct_gradient(
        &self,
        dx: &CausalTensor<T>,
        dy: &CausalTensor<T>,
        dz: &CausalTensor<T>,
    ) -> Self
    where
        T: Ring + std::ops::Neg<Output = T>,
    {
        let n = self.metric.dimension();
        let gammas = gamma::get_gammas::<T>(&self.metric);
        let matrix_dim = Self::compute_matrix_dim(n);

        // Applies gamma matrix to a field tensor
        let apply_gamma = |gamma_idx: usize, t: &CausalTensor<T>| -> CausalTensor<T> {
            let shape_t = t.shape().to_vec();
            let batch_size = shape_t[0] * shape_t[1] * shape_t[2];

            // Get gamma matrix for this index
            let gamma_mat = gammas.slice(0, gamma_idx).expect("slice gamma failed");
            let gamma_data = gamma_mat.to_vec();

            // Get field data
            let t_flat = t
                .reshape(&[batch_size, matrix_dim, matrix_dim])
                .expect("reshape failed");
            let t_data = t_flat.to_vec();

            // Perform batched matrix multiplication manually
            let mut result_data = vec![T::zero(); batch_size * matrix_dim * matrix_dim];

            for b in 0..batch_size {
                for i in 0..matrix_dim {
                    for j in 0..matrix_dim {
                        let mut sum = T::zero();
                        for k in 0..matrix_dim {
                            let g_ik = gamma_data[i * matrix_dim + k];
                            let t_kj = t_data[b * matrix_dim * matrix_dim + k * matrix_dim + j];
                            sum = sum + g_ik * t_kj;
                        }
                        result_data[b * matrix_dim * matrix_dim + i * matrix_dim + j] = sum;
                    }
                }
            }

            let result_flat =
                CausalTensor::from_slice(&result_data, &[batch_size, matrix_dim, matrix_dim]);
            let orig_shape = [shape_t[0], shape_t[1], shape_t[2], matrix_dim, matrix_dim];
            result_flat.reshape(&orig_shape).expect("reshape failed")
        };

        // Term X: dx * Gamma_0
        let term_x = apply_gamma(0, dx);

        if n < 2 {
            return Self {
                data: term_x,
                metric: self.metric,
                dx: self.dx,
                shape: self.shape,
            };
        }

        // Term Y: dy * Gamma_1
        let term_y = apply_gamma(1, dy);
        let sum_xy = &term_x + &term_y;

        if n < 3 {
            return Self {
                data: sum_xy,
                metric: self.metric,
                dx: self.dx,
                shape: self.shape,
            };
        }

        // Term Z: dz * Gamma_2
        let term_z = apply_gamma(2, dz);
        let result = &sum_xy + &term_z;

        Self {
            data: result,
            metric: self.metric,
            dx: self.dx,
            shape: self.shape,
        }
    }
}
