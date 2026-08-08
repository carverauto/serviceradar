/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError, Tensor};
use deep_causality_algebra::RealField;
use deep_causality_num::{One, Zero};

impl<T: Default> CausalTensor<T> {
    pub(in crate::types::causal_tensor) fn solve_least_squares_cholsky_impl(
        a: &Self, // Design matrix (m x n)
        b: &Self, // Observation vector (m x 1)
    ) -> Result<Self, CausalTensorError>
    where
        T: Default + Clone + RealField + Zero + One + Copy + PartialEq,
    {
        // Input validation
        if a.num_dim() != 2 || b.num_dim() != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let m = a.shape()[0];
        let n = a.shape()[1]; // Number of parameters
        if b.shape()[0] != m || b.shape()[1] != 1 {
            return Err(CausalTensorError::ShapeMismatch); // b must be a column vector
        }

        // 1. Calculate A^T using a strided view via permute_axes
        let a_t = a.permute_axes(&[1, 0])?;

        // 2. Calculate M = A^T A
        let m_matrix = CausalTensor::mat_mul_2d(&a_t, a)?;

        // 3. Calculate y = A^T b
        let y_vector = CausalTensor::mat_mul_2d(&a_t, b)?;

        // 4. Cholesky decomposition of M: M = LL^T
        let l_matrix = m_matrix.cholesky_decomposition_impl()?;

        // 5. Solve Lz = y for z (forward substitution)
        let z_data = vec![T::zero(); n];
        let mut z_vector = CausalTensor::from_vec_and_shape_unchecked(z_data, &[n, 1]);

        for i in 0..n {
            let mut sum = T::zero();
            for j in 0..i {
                sum += *l_matrix.get_ref(i, j)? * *z_vector.get_ref(j, 0)?;
            }
            let val = (*y_vector.get_ref(i, 0)? - sum) / *l_matrix.get_ref(i, i)?;
            z_vector.set(i, 0, val)?;
        }

        // 6. Solve L^T x = z for x (backward substitution)
        // Here we CAN use permute_axes because we access elements via get_ref, which respects strides.
        let l_t_matrix = l_matrix.permute_axes(&[1, 0])?; // L^T

        let x_data = vec![T::zero(); n];
        let mut x_vector = CausalTensor::from_vec_and_shape_unchecked(x_data, &[n, 1]);

        for i in (0..n).rev() {
            let mut sum = T::zero();
            for j in i + 1..n {
                sum += *l_t_matrix.get_ref(i, j)? * *x_vector.get_ref(j, 0)?;
            }
            let val = (*z_vector.get_ref(i, 0)? - sum) / *l_t_matrix.get_ref(i, i)?;
            x_vector.set(i, 0, val)?;
        }
        Ok(x_vector)
    }

    pub(in crate::types::causal_tensor) fn cholesky_decomposition_impl(
        &self,
    ) -> Result<Self, CausalTensorError>
    where
        T: Default + Clone + RealField + Zero + One + PartialEq,
    {
        // Input validation: Must be a square matrix
        let num_dim = self.num_dim();
        if num_dim != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }
        let n = self.shape()[0];
        if n != self.shape()[1] {
            return Err(CausalTensorError::ShapeMismatch);
        }

        let l_data = vec![T::zero(); n * n];
        let mut l_matrix = CausalTensor::from_vec_and_shape_unchecked(l_data, &[n, n]);

        for i in 0..n {
            for j in 0..i + 1 {
                // Iterate up to and including the diagonal
                let mut sum = T::zero();
                for k in 0..j {
                    sum += *l_matrix.get_ref(i, k)? * *l_matrix.get_ref(j, k)?;
                }

                if i == j {
                    // Diagonal elements
                    let val = *self.get_ref(i, i)? - sum;
                    if val <= T::zero() {
                        // Check for positive definiteness
                        return Err(CausalTensorError::SingularMatrix); // Not positive definite
                    }
                    let sqrt_val = val.sqrt(); // Need a sqrt method on T
                    l_matrix.set(i, j, sqrt_val)?;
                } else {
                    // Off-diagonal elements
                    let val = (*self.get_ref(i, j)? - sum) / *l_matrix.get_ref(j, j)?;
                    l_matrix.set(i, j, val)?;
                }
            }
        }
        Ok(l_matrix)
    }
}
