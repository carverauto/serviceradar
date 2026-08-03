/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CsrMatrix;
use deep_causality_num::Zero;

impl<T> CsrMatrix<T> {
    /// Computes the transpose of the matrix: \( B = A^T \).
    ///
    /// Given a matrix \( A \) of shape \( m \times n \), its transpose \( B \) is a matrix
    /// of shape \( n \times m \), where the rows of \( A \) become the columns of \( B \)
    /// and the columns of \( A \) become the rows of \( B \). Formally,
    /// \( B_{ij} = A_{ji} \).
    ///
    /// Returns a new `CsrMatrix` representing the transpose.
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
    /// let a_t = a.transpose();
    /// // A^T (3x2) = [[1.0, 0.0], [0.0, 3.0], [2.0, 0.0]]
    ///
    /// assert_eq!(a_t.shape(), (3, 2));
    /// assert_eq!(a_t.get_value_at(0, 0), 1.0);
    /// assert_eq!(a_t.get_value_at(1, 1), 3.0);
    /// assert_eq!(a_t.get_value_at(2, 0), 2.0);
    /// ```
    /// Transposes the CSR matrix.
    ///
    /// This uses a linear-time Counting Sort algorithm ($O(NNZ + N_{cols})$).
    /// 1. Computes the histogram of column counts.
    /// 2. Computes the prefix sum to find row pointers for the new matrix.
    /// 3. Scatters the values into the new position.
    ///
    /// Note: The resulting matrix automatically has sorted column indices within each row,
    /// even if the input did not, because we iterate through the input rows sequentially.
    pub(crate) fn transpose_impl(&self) -> Self
    where
        T: Copy + Zero, // Copy is essential for fast vector initialization
    {
        let (rows, cols) = self.shape;
        let nnz = self.values.len();

        // 1. Allocate and Count (Histogram)
        // b_row_indices will eventually hold the row pointers.
        // Initially, we use it to count the number of non-zeros per column.
        let mut b_row_indices = vec![0; cols + 1];

        for &col_idx in &self.col_indices {
            // In a valid CSR matrix, col_idx < cols.
            // We skip bounds check for speed, relying on Vec's internal check if it fails.
            b_row_indices[col_idx + 1] += 1;
        }

        // 2. Prefix Sum (CumSum)
        // Transform counts into start pointers.
        // b_row_indices[i] is now the starting index of row i in the transposed matrix.
        for i in 0..cols {
            b_row_indices[i + 1] += b_row_indices[i];
        }

        // 3. Allocate Result Arrays
        // Without `unsafe`, we must initialize these.
        // T: Copy + Zero makes this a fast memset/calloc operation.
        let mut b_col_indices = vec![0; nnz];
        let mut b_values = vec![T::zero(); nnz];

        // 4. Scatter / Fill
        // We need mutable pointers to track where we are writing in each row of the new matrix.
        // Cloning b_row_indices is cheap (size = cols) compared to the data size.
        // 'current_positions[c]' tracks the next write index for column 'c'.
        let mut current_positions = b_row_indices.clone();

        for r in 0..rows {
            let start = self.row_indices[r];
            let end = self.row_indices[r + 1];

            for k in start..end {
                let c = self.col_indices[k]; // Original Column -> New Row
                let val = self.values[k];

                // Get the write position for this column
                let dest = current_positions[c];

                b_col_indices[dest] = r; // Original Row -> New Column
                b_values[dest] = val;

                current_positions[c] += 1;
            }
        }

        Self {
            row_indices: b_row_indices,
            col_indices: b_col_indices,
            values: b_values,
            shape: (cols, rows), // Swapped dimensions
        }
    }
}
