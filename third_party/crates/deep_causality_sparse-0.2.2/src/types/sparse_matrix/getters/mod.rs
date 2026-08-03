/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::CsrMatrix;
use deep_causality_num::Zero;

impl<T> CsrMatrix<T> {
    /// Returns a reference to the internal `row_indices` vector.
    ///
    /// This vector stores the starting index in `col_indices` and `values`
    /// for each row of the matrix, plus one extra element at the end indicating
    /// the total number of non-zero elements.
    ///
    /// # Returns
    /// A reference to a `Vec<usize>` representing the row pointers.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::from_triplets(
    ///     2, 3, &[(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)]
    /// ).unwrap();
    /// assert_eq!(matrix.row_indices(), &vec![0, 2, 3]);
    /// ```
    pub fn row_indices(&self) -> &Vec<usize> {
        &self.row_indices
    }

    /// Returns a reference to the internal `col_indices` vector.
    ///
    /// This vector stores the column index for each non-zero element in the matrix,
    /// ordered by row, then by column within each row.
    ///
    /// # Returns
    /// A reference to a `Vec<usize>` representing the column indices of non-zero elements.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::from_triplets(
    ///     2, 3, &[(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)]
    /// ).unwrap();
    /// assert_eq!(matrix.col_indices(), &vec![0, 2, 1]);
    /// ```
    pub fn col_indices(&self) -> &Vec<usize> {
        &self.col_indices
    }

    /// Returns a reference to the internal `values` vector.
    ///
    /// This vector stores the actual non-zero values of the matrix,
    /// corresponding to the column indices in `col_indices`.
    ///
    /// # Returns
    /// A reference to a `Vec<T>` representing the non-zero values.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::from_triplets(
    ///     2, 3, &[(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)]
    /// ).unwrap();
    /// assert_eq!(matrix.values(), &vec![1.0, 2.0, 3.0]);
    /// ```
    pub fn values(&self) -> &Vec<T> {
        &self.values
    }

    /// Returns the shape (dimensions) of the matrix.
    ///
    /// The shape is returned as a tuple `(rows, cols)`.
    ///
    /// # Returns
    /// A tuple `(usize, usize)` representing the number of rows and columns.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::with_capacity(5, 10, 0);
    /// assert_eq!(matrix.shape(), (5, 10));
    /// ```
    pub fn shape(&self) -> (usize, usize) {
        self.shape
    }
}

impl<T> CsrMatrix<T> {
    /// Retrieves the value at the specified row and column index.
    /// Returns `T::zero()` if the index is out of bounds or the element is zero.
    ///
    /// # Arguments
    /// * `row_idx` - The row index.
    /// * `col_idx` - The column index.
    ///
    /// # Returns
    /// The value at `(row_idx, col_idx)` or `T::zero()` if not found or out of bounds.
    pub fn get_value_at(&self, row_idx: usize, col_idx: usize) -> T
    where
        T: Copy + Zero + PartialEq,
    {
        if row_idx >= self.shape.0 || col_idx >= self.shape.1 {
            return T::zero(); // Out of bounds
        }

        let start = self.row_indices[row_idx];
        let end = self.row_indices[row_idx + 1];

        // Perform a binary search for the column index in the current row
        let slice = &self.col_indices[start..end];
        match slice.binary_search(&col_idx) {
            Ok(idx_in_slice) => self.values[start + idx_in_slice],
            Err(_) => T::zero(),
        }
    }
}
