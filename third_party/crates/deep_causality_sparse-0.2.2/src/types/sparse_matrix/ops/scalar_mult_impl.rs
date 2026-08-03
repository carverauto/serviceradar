/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use std::ops::Mul;

impl<T> CsrMatrix<T> {
    /// Performs scalar multiplication: \( B = s \cdot A \).
    ///
    /// Given a matrix \( A \) and a scalar \( s \), their product \( B \) is a matrix
    /// of the same shape as \( A \), where each element \( B_{ij} \) is the product of
    /// the scalar \( s \) and the corresponding element \( A_{ij} \):
    /// \( B_{ij} = s \cdot A_{ij} \).
    ///
    /// Returns a new `CsrMatrix` where each element is multiplied by the scalar.
    ///
    /// # Arguments
    ///
    /// * `scalar` - The scalar value to multiply by.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    /// use deep_causality_num::Zero;
    ///
    /// let a = CsrMatrix::from_triplets(2, 2, &[(0, 0, 1.0), (1, 1, 2.0)]).unwrap();
    /// // A = [[1.0, 0.0], [0.0, 2.0]]
    ///
    /// let c = a.scalar_mult(3.0);
    /// // C = 3 * A = [[3.0, 0.0], [0.0, 6.0]]
    ///
    /// assert_eq!(c.get_value_at(0, 0), 3.0);
    /// assert_eq!(c.get_value_at(1, 1), 6.0);
    /// ```
    pub(crate) fn scalar_mult_impl(&self, scalar: T) -> Self
    where
        T: Copy + Clone + Mul<Output = T>,
    {
        let new_values: Vec<T> = self.values.iter().map(|&val| val * scalar).collect();
        Self {
            row_indices: self.row_indices.clone(),
            col_indices: self.col_indices.clone(),
            values: new_values,
            shape: self.shape,
        }
    }
}
