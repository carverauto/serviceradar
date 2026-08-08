/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsrMatrix, SparseMatrixError};
use deep_causality_num::Zero;
use std::ops::Mul;

impl<T> CsrMatrix<T> {
    /// Performs matrix multiplication: \( C = A \cdot B \).
    ///
    /// Given two matrices \( A \) (self) of shape \( m \times k \) and \( B \) (other) of shape \( k \times n \),
    /// their product \( C \) is a matrix of shape \( m \times n \). Each element \( C_{ij} \) is the
    /// dot product of the \( i \)-th row of \( A \) and the \( j \)-th column of \( B \):
    /// \( C_{ij} = \sum_{p=0}^{k-1} A_{ip} B_{pj} \).
    ///
    /// Returns a new `CsrMatrix` representing the product of the two matrices,
    /// or a `SparseMatrixError::DimensionMismatch` if their dimensions are not compatible.
    ///
    /// # Arguments
    ///
    /// * `other` - The matrix to multiply by.
    ///
    /// # Errors
    ///
    /// Returns `SparseMatrixError::DimensionMismatch` if the matrices have incompatible dimensions
    /// for multiplication (self.cols != other.rows).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    /// use deep_causality_num::Zero;
    ///
    /// let a = CsrMatrix::from_triplets(2, 3, &[(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)]).unwrap();
    /// // A (2x3) = [[1.0, 0.0, 2.0], [0.0, 3.0, 0.0]]
    ///
    /// let b = CsrMatrix::from_triplets(3, 2, &[(0, 0, 4.0), (1, 1, 5.0), (2, 0, 6.0)]).unwrap();
    /// // B (3x2) = [[4.0, 0.0], [0.0, 5.0], [6.0, 0.0]]
    ///
    /// let c = a.mat_mult(&b).unwrap();
    /// // C = A * B (2x2) = [[(1*4+0*0+2*6), (1*0+0*5+2*0)], [(0*4+3*0+0*6), (0*0+3*5+0*0)]]
    /// //                 = [[16.0, 0.0], [0.0, 15.0]]
    ///
    /// assert_eq!(c.get_value_at(0, 0), 16.0);
    /// assert_eq!(c.get_value_at(0, 1), 0.0);
    /// assert_eq!(c.get_value_at(1, 0), 0.0);
    /// assert_eq!(c.get_value_at(1, 1), 15.0);
    /// ```
    /// Optimized implementation of Compressed Sparse Row (CSR) matrix multiplication.
    ///
    /// Uses Gustavson's algorithm with a marker array to avoid zeroing out the
    /// dense accumulator for every row.
    pub(crate) fn mat_mult_impl(&self, other: &Self) -> Result<Self, SparseMatrixError>
    where
        T: Copy + Clone + Mul<Output = T> + Zero + PartialEq + Default,
    {
        if self.shape.1 != other.shape.0 {
            return Err(SparseMatrixError::DimensionMismatch(
                self.shape.1,
                other.shape.0,
            ));
        }

        let n_rows = self.shape.0;
        let n_cols = other.shape.1;

        // Heuristic for reserving memory:
        // Assume the result has roughly the same density factor as the inputs.
        // This prevents frequent reallocations of the result vectors.
        let estimated_nnz = self.values.len().saturating_add(other.values.len());

        let mut row_indices = Vec::with_capacity(n_rows + 1);
        let mut col_indices = Vec::with_capacity(estimated_nnz);
        let mut values = Vec::with_capacity(estimated_nnz);

        // Dense accumulator for values in the current row.
        // We do NOT clear this vector between rows.
        let mut dense_vals = vec![T::zero(); n_cols];

        // Marker array to track which columns have been visited in the current row.
        // If marker[col] == current_row_index, the value in dense_vals[col] is valid.
        // Initialize with usize::MAX so it doesn't match the first row index (0).
        let mut marker = vec![usize::MAX; n_cols];

        // Stores the column indices touched in the current row operation.
        // We maintain this to sort indices and gather results efficiently.
        let mut current_row_cols = Vec::with_capacity(n_cols.min(1024)); // Cap initial alloc

        row_indices.push(0);

        for i in 0..n_rows {
            // Iterate over non-zeros in row i of Matrix A
            let start_a = self.row_indices[i];
            let end_a = self.row_indices[i + 1];

            for ptr_a in start_a..end_a {
                let col_a = self.col_indices[ptr_a]; // This corresponds to a row in Matrix B
                let val_a = self.values[ptr_a];

                // Skip computation if A's value is zero (preserves sparsity)
                if val_a == T::zero() {
                    continue;
                }

                let start_b = other.row_indices[col_a];
                let end_b = other.row_indices[col_a + 1];

                // Iterate over non-zeros in row col_a of Matrix B
                for ptr_b in start_b..end_b {
                    let col_b = other.col_indices[ptr_b];
                    let val_b = other.values[ptr_b];

                    let prod = val_a * val_b;

                    // Gustavson's Logic: Check timestamp
                    if marker[col_b] == i {
                        // We have already visited this column in this row step.
                        // Accumulate the value.
                        dense_vals[col_b] = dense_vals[col_b] + prod;
                    } else {
                        // First time visiting this column for this row.
                        // Update marker, record column index, and set initial value.
                        marker[col_b] = i;
                        current_row_cols.push(col_b);
                        dense_vals[col_b] = prod;
                    }
                }
            }

            // CSR requires column indices within a row to be sorted.
            // unstable sort is faster and fine for primitives (usize).
            current_row_cols.sort_unstable();

            // Gather phase: Collect non-zero results into the final vectors
            for &col in &current_row_cols {
                let val = dense_vals[col];
                if val != T::zero() {
                    col_indices.push(col);
                    values.push(val);
                }
            }

            // Record the end pointer for the current row
            row_indices.push(values.len());

            // Prepare for next row:
            // We clear the list of columns, but we DO NOT need to clear
            // dense_vals or marker. The 'i' increment handles the logic.
            current_row_cols.clear();
        }

        Ok(Self {
            row_indices,
            col_indices,
            values,
            shape: (n_rows, n_cols),
        })
    }
}
