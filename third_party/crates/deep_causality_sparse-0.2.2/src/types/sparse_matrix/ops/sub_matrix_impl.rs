/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CsrMatrix, SparseMatrixError};
use deep_causality_num::Zero;

impl<T> CsrMatrix<T> {
    /// Performs matrix subtraction: \( C = A - B \).
    ///
    /// Given two matrices \( A \) (self) and \( B \) (other) of the same shape \( m \times n \),
    /// their difference \( C \) is a matrix of the same shape where each element \( C_{ij} \) is the
    /// difference of the corresponding elements in \( A \) and \( B \):
    /// \( C_{ij} = A_{ij} - B_{ij} \).
    ///
    /// Returns a new `CsrMatrix` representing the difference of the two matrices,
    /// or a `SparseMatrixError::ShapeMismatch` if their shapes are not compatible.
    ///
    /// # Arguments
    ///
    /// * `other` - The matrix to subtract.
    ///
    /// # Errors
    ///
    /// Returns `SparseMatrixError::ShapeMismatch` if the matrices have different dimensions.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    /// use deep_causality_num::Zero;
    ///
    /// let a = CsrMatrix::from_triplets(2, 2, &[(0, 0, 5.0), (0, 1, 2.0), (1, 1, 3.0)]).unwrap();
    /// // A = [[5.0, 2.0], [0.0, 3.0]]
    ///
    /// let b = CsrMatrix::from_triplets(2, 2, &[(0, 0, 1.0), (1, 1, 1.0)]).unwrap();
    /// // B = [[1.0, 0.0], [0.0, 1.0]]
    ///
    /// let c = a.sub_matrix(&b).unwrap();
    /// // C = A - B = [[4.0, 2.0], [0.0, 2.0]]
    ///
    /// assert_eq!(c.get_value_at(0, 0), 4.0);
    /// assert_eq!(c.get_value_at(0, 1), 2.0);
    /// assert_eq!(c.get_value_at(1, 0), 0.0);
    /// assert_eq!(c.get_value_at(1, 1), 2.0);
    /// ```
    pub(crate) fn sub_matrix_impl(&self, other: &Self) -> Result<Self, SparseMatrixError>
    where
        T: Copy + Zero + std::ops::Sub<Output = T> + PartialEq,
    {
        if self.shape != other.shape {
            return Err(SparseMatrixError::ShapeMismatch(self.shape, other.shape));
        }

        let rows = self.shape.0;
        let cols = self.shape.1;

        // Heuristic: Result NNZ <= Sum of input NNZs.
        let max_nnz = self.values.len() + other.values.len();

        let mut new_row_indices = Vec::with_capacity(rows + 1);
        let mut new_col_indices = Vec::with_capacity(max_nnz);
        let mut new_values = Vec::with_capacity(max_nnz);

        new_row_indices.push(0);

        for i in 0..rows {
            let range_a = self.row_indices[i]..self.row_indices[i + 1];
            let range_b = other.row_indices[i]..other.row_indices[i + 1];

            let mut ptr_a = range_a.start;
            let end_a = range_a.end;

            let mut ptr_b = range_b.start;
            let end_b = range_b.end;

            // PHASE 1: Overlap - Iterate while BOTH rows have data
            while ptr_a < end_a && ptr_b < end_b {
                let col_a = self.col_indices[ptr_a];
                let col_b = other.col_indices[ptr_b];

                if col_a < col_b {
                    // A has a value, B is implicitly 0. Result = A - 0 = A.
                    let val = self.values[ptr_a];
                    if val != T::zero() {
                        new_col_indices.push(col_a);
                        new_values.push(val);
                    }
                    ptr_a += 1;
                } else if col_b < col_a {
                    // B has a value, A is implicitly 0. Result = 0 - B = -B.
                    let val = other.values[ptr_b];
                    let sub_val = T::zero() - val; // Negate B
                    if sub_val != T::zero() {
                        new_col_indices.push(col_b);
                        new_values.push(sub_val);
                    }
                    ptr_b += 1;
                } else {
                    // Columns match. Result = A - B.
                    let val = self.values[ptr_a] - other.values[ptr_b];
                    if val != T::zero() {
                        new_col_indices.push(col_a);
                        new_values.push(val);
                    }
                    ptr_a += 1;
                    ptr_b += 1;
                }
            }

            // PHASE 2: Flush remaining A (A - 0 = A)
            while ptr_a < end_a {
                let val = self.values[ptr_a];
                if val != T::zero() {
                    new_col_indices.push(self.col_indices[ptr_a]);
                    new_values.push(val);
                }
                ptr_a += 1;
            }

            // PHASE 3: Flush remaining B (0 - B = -B)
            while ptr_b < end_b {
                let val = other.values[ptr_b];
                let sub_val = T::zero() - val;
                if sub_val != T::zero() {
                    new_col_indices.push(other.col_indices[ptr_b]);
                    new_values.push(sub_val);
                }
                ptr_b += 1;
            }

            new_row_indices.push(new_values.len());
        }

        Ok(Self {
            row_indices: new_row_indices,
            col_indices: new_col_indices,
            values: new_values,
            shape: (rows, cols),
        })
    }
}
