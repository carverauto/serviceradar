/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::RealField;
use deep_causality_num::{One, Zero};

impl<T> CausalTensor<T> {
    pub(in crate::types::causal_tensor) fn inverse_impl(&self) -> Result<Self, CausalTensorError>
    where
        T: Clone + RealField + Zero + One + Copy + PartialEq,
    {
        let num_dim = self.num_dim();
        if num_dim != 2 {
            return Err(CausalTensorError::DimensionMismatch);
        }

        let rows = self.shape()[0];
        let cols = self.shape()[1];

        if rows != cols {
            return Err(CausalTensorError::ShapeMismatch); // Not a square matrix
        }

        let n = rows;

        // Handle 1x1 matrix case
        if n == 1 {
            let val = self.data[0];
            if val.is_zero() {
                return Err(CausalTensorError::SingularMatrix);
            }
            return Self::new(vec![T::one() / val], vec![1, 1]); // Should not fail for 1x1
        }

        // Create an augmented matrix [A | I]
        let mut augmented_data = Vec::with_capacity(n * 2 * n);
        for r in 0..n {
            for c in 0..n {
                augmented_data.push(*self.get_ref(r, c)?);
            }
            for c in 0..n {
                if r == c {
                    augmented_data.push(T::one());
                } else {
                    augmented_data.push(T::zero());
                }
            }
        }

        let mut augmented_matrix = Self::from_vec_and_shape_unchecked(augmented_data, &[n, 2 * n]);

        // Gaussian Elimination
        for i in 0..n {
            // Estimate scale using max absolute value in column i
            let mut pivot_row = i;
            let mut max_val = T::zero();
            for r in i..n {
                let current_val = augmented_matrix.get_ref(r, i)?.abs();
                if current_val > max_val {
                    max_val = current_val;
                    pivot_row = r;
                }
            }
            // Use relative threshold: tol = epsilon * max(1, max_val)
            let one = T::one();
            let tol = T::epsilon() * if max_val > one { max_val } else { one };
            if max_val <= tol {
                return Err(CausalTensorError::SingularMatrix);
            }

            // Swap pivot row with current row if necessary
            if pivot_row != i {
                for c in 0..2 * n {
                    let a = *augmented_matrix.get_ref(i, c)?;
                    let b = *augmented_matrix.get_ref(pivot_row, c)?;
                    augmented_matrix.set(i, c, b)?;
                    augmented_matrix.set(pivot_row, c, a)?;
                }
            }

            // Normalize pivot row across ALL columns to make pivot exactly 1
            let pivot_val = *augmented_matrix.get_ref(i, i)?;
            if pivot_val.abs() < T::epsilon() {
                return Err(CausalTensorError::DivisionByZero);
            }
            for c in 0..2 * n {
                let val = *augmented_matrix.get_ref(i, c)?;
                augmented_matrix.set(i, c, val / pivot_val)?;
            }

            // Eliminate other rows
            for r in 0..n {
                if r == i {
                    continue;
                }
                let factor = *augmented_matrix.get_ref(r, i)?;
                if factor.abs() < T::epsilon() {
                    continue;
                }
                for c in 0..2 * n {
                    let v_rc = *augmented_matrix.get_ref(r, c)?;
                    let v_ic = *augmented_matrix.get_ref(i, c)?;
                    augmented_matrix.set(r, c, v_rc - factor * v_ic)?;
                }
            }
        }

        // Extract the inverse matrix
        let mut inverse_data = Vec::with_capacity(n * n);
        for r in 0..n {
            for c in n..2 * n {
                inverse_data.push(*augmented_matrix.get_ref(r, c)?); // Use get and ?
            }
        }

        Ok(Self::from_vec_and_shape_unchecked(inverse_data, &[n, n]))
    }
}
