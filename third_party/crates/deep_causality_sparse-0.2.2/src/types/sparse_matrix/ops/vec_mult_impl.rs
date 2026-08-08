/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsrMatrix, SparseMatrixError};
use deep_causality_num::Zero;
use std::ops::Mul;

impl<T> CsrMatrix<T> {
    /// Performs matrix-vector multiplication: \( y = Ax \).
    ///
    /// Given a matrix \( A \) of shape \( m \times n \) (self) and a vector \( x \) of length \( n \),
    /// their product \( y \) is a vector of length \( m \), where each element \( y_i \) is the
    /// dot product of the \( i \)-th row of \( A \) and the vector \( x \):
    /// \( y_i = \sum_{j=0}^{n-1} A_{ij} x_j \).
    ///
    /// # Arguments
    /// * `x` - The vector to multiply by. It is expected to have a length equal to the number of columns in the matrix.
    ///
    /// # Returns
    /// A `Result<Vec<T>, SparseMatrixError>` representing the resulting vector, or an error.
    ///
    /// # Errors
    /// Returns `SparseMatrixError::DimensionMismatch` if the length of `x` does not match
    /// the number of columns in the matrix (`self.shape.1`).
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    /// use deep_causality_num::Zero;
    ///
    /// let a = CsrMatrix::from_triplets(2, 3, &[(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)]).unwrap();
    /// // A = [[1.0, 0.0, 2.0], [0.0, 3.0, 0.0]]
    ///
    /// let x = vec![1.0, 2.0, 3.0];
    ///
    /// let y = a.vec_mult(&x).unwrap();
    /// // y = Ax = [(1.0*1.0 + 0.0*2.0 + 2.0*3.0), (0.0*1.0 + 3.0*2.0 + 0.0*3.0)] = [7.0, 6.0]
    ///
    /// assert_eq!(y, vec![7.0, 6.0]);
    ///
    /// // Example of error handling
    /// let x_invalid = vec![1.0, 2.0]; // Incorrect length
    /// let err = a.vec_mult(&x_invalid).unwrap_err();
    /// assert!(matches!(err, deep_causality_sparse::SparseMatrixError::DimensionMismatch(3, 2)));
    /// ```
    pub(crate) fn vec_mult_impl(&self, x: &[T]) -> Result<Vec<T>, SparseMatrixError>
    where
        T: Copy + Zero + std::ops::Add<Output = T> + Mul<Output = T>,
    {
        if x.len() != self.shape.1 {
            return Err(SparseMatrixError::DimensionMismatch(self.shape.1, x.len()));
        }

        let rows = self.shape.0;
        let mut y = Vec::with_capacity(rows);

        // We assume T is cheap to copy (f32, f64, etc).
        // Iterate through rows.
        for i in 0..rows {
            let start = self.row_indices[i];
            let end = self.row_indices[i + 1];

            // Create slice views for the current row.
            // This helps the compiler eliminate bounds checks on 'self' arrays
            // within the inner loop, as the slice length is known.
            let row_cols = &self.col_indices[start..end];
            let row_vals = &self.values[start..end];

            // Sequential accumulation for numerical stability.
            // This avoids catastrophic cancellation that can occur with parallel
            // accumulators when a row contains large values with opposite signs
            // (e.g., 1e20 and -1e20) alongside smaller values.
            let mut final_sum = T::zero();

            for (&c, &v) in row_cols.iter().zip(row_vals.iter()) {
                final_sum = final_sum + (v * x[c]);
            }

            y.push(final_sum);
        }
        Ok(y)
    }
}
