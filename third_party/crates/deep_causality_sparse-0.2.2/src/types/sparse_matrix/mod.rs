/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

mod algebra;
mod api;
mod arithmetic;
mod display;
mod getters;
mod identity;
mod ops;

use crate::SparseMatrixError;
use deep_causality_num::Zero;

/// A Compressed Sparse Row Matrix.
#[derive(Clone, Debug, PartialEq)]
pub struct CsrMatrix<T> {
    pub(crate) row_indices: Vec<usize>,
    pub(crate) col_indices: Vec<usize>,
    pub(crate) values: Vec<T>,
    pub(crate) shape: (usize, usize), // (Rows, Cols)
}

impl<T> Default for CsrMatrix<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> CsrMatrix<T> {
    /// Creates a new, empty `CsrMatrix`.
    ///
    /// The matrix will have zero rows and columns and no stored elements.
    /// Its shape will be `(0, 0)`.
    ///
    /// # Returns
    /// A new, empty `CsrMatrix`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::new();
    /// assert_eq!(matrix.shape(), (0, 0));
    /// assert!(matrix.values().is_empty());
    /// ```
    pub fn new() -> Self {
        Self {
            row_indices: Vec::new(),
            col_indices: Vec::new(),
            values: Vec::new(),
            shape: (0, 0),
        }
    }

    /// Creates a new `CsrMatrix` with pre-allocated capacity for its internal vectors.
    ///
    /// This can improve performance by reducing reallocations when a large number of
    /// elements are expected to be added to the matrix after creation.
    /// The matrix is initially logically empty (all zeros) with the specified `shape`.
    ///
    /// # Arguments
    /// * `rows` - The number of rows the matrix will have.
    /// * `cols` - The number of columns the matrix will have.
    /// * `capacity` - The estimated number of non-zero elements the matrix will store.
    ///
    /// # Returns
    /// A new `CsrMatrix` with the specified shape and allocated capacity.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let matrix: CsrMatrix<f64> = CsrMatrix::with_capacity(5, 5, 10);
    /// assert_eq!(matrix.shape(), (5, 5));
    /// assert!(matrix.values().capacity() >= 10);
    /// assert_eq!(matrix.row_indices().len(), 6); // rows + 1
    /// assert!(matrix.col_indices().is_empty());
    /// ```
    pub fn with_capacity(rows: usize, cols: usize, capacity: usize) -> Self {
        Self {
            row_indices: vec![0; rows + 1],
            col_indices: Vec::with_capacity(capacity),
            values: Vec::with_capacity(capacity),
            shape: (rows, cols),
        }
    }

    /// Consumes the matrix and returns its internal components:
    /// `(row_indices, col_indices, values, shape)`.
    pub fn into_parts(self) -> (Vec<usize>, Vec<usize>, Vec<T>, (usize, usize)) {
        (self.row_indices, self.col_indices, self.values, self.shape)
    }

    /// Returns a new `CsrMatrix` with the same sparsity structure, applying `f`
    /// to each stored value.
    ///
    /// The row indices, column indices, and shape are preserved exactly; only the
    /// stored value type changes (`T` -> `U`). Because the structure is carried
    /// over unchanged, this is a safe, allocation-free-structure remap and cannot
    /// produce an invalid matrix.
    pub fn map_values<U, F>(self, f: F) -> CsrMatrix<U>
    where
        F: FnMut(T) -> U,
    {
        CsrMatrix {
            row_indices: self.row_indices,
            col_indices: self.col_indices,
            values: self.values.into_iter().map(f).collect(),
            shape: self.shape,
        }
    }
}
impl<T> CsrMatrix<T>
where
    T: Clone + Copy + Zero + PartialEq,
{
    /// Creates a new `CsrMatrix` from a list of `(row, col, value)` triplets.
    ///
    /// The `from_triplets` function constructs a sparse matrix \( A \) of size \( m \times n \)
    /// (where \( m \) is `rows` and \( n \) is `cols`) from a list of \( (r, c, v) \) triplets.
    /// Each triplet represents a non-zero element \( A_{rc} = v \).
    /// If multiple triplets specify the same \( (r, c) \) position, their values are summed:
    /// \( A_{rc} = \sum v_i \) for all \( v_i \) at \( (r, c) \).
    /// Triplets whose summed value is zero are discarded.
    ///
    /// The triplets are sorted, and duplicate `(row, col)` entries have their
    /// values summed.
    ///
    /// # Arguments
    /// * `rows` - The number of rows in the matrix.
    /// * `cols` - The number of columns in the matrix.
    /// * `triplets` - A slice of `(row_idx, col_idx, value)` tuples.
    ///
    /// # Errors
    /// Returns `SparseMatrixError::IndexOutOfBounds` if any triplet's indices
    /// are outside the specified matrix dimensions.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    /// use deep_causality_num::Zero;
    ///
    /// // Example 1: Basic construction
    /// let triplets1 = vec![(0, 0, 1.0), (0, 2, 2.0), (1, 1, 3.0)];
    /// let matrix1 = CsrMatrix::from_triplets(2, 3, &triplets1).unwrap();
    /// // matrix1 will represent:
    /// // [1.0, 0.0, 2.0]
    /// // [0.0, 3.0, 0.0]
    /// assert_eq!(matrix1.values(), &vec![1.0, 2.0, 3.0]);
    /// assert_eq!(matrix1.col_indices(), &vec![0, 2, 1]);
    /// assert_eq!(matrix1.row_indices(), &vec![0, 2, 3]);
    /// assert_eq!(matrix1.shape(), (2, 3));
    ///
    /// // Example 2: With duplicate entries
    /// let triplets2 = vec![(0, 0, 1.0), (0, 0, 0.5), (1, 1, 3.0)];
    /// let matrix2 = CsrMatrix::from_triplets(2, 2, &triplets2).unwrap();
    /// // matrix2 will represent:
    /// // [1.5, 0.0]
    /// // [0.0, 3.0]
    /// assert_eq!(matrix2.values(), &vec![1.5, 3.0]);
    /// assert_eq!(matrix2.col_indices(), &vec![0, 1]);
    /// assert_eq!(matrix2.row_indices(), &vec![0, 1, 2]);
    /// assert_eq!(matrix2.shape(), (2, 2));
    ///
    /// // Example 3: With zero-valued entries after summation
    /// let triplets3 = vec![(0, 0, 1.0), (0, 0, -1.0), (1, 1, 3.0)];
    /// let matrix3 = CsrMatrix::from_triplets(2, 2, &triplets3).unwrap();
    /// // matrix3 will represent:
    /// // [0.0, 0.0]
    /// // [0.0, 3.0]
    /// assert_eq!(matrix3.values(), &vec![3.0]);
    /// assert_eq!(matrix3.col_indices(), &vec![1]);
    /// assert_eq!(matrix3.row_indices(), &vec![0, 0, 1]); // Note: row_indices[0]=0, row_indices[1]=0 as row 0 has no non-zeros
    /// assert_eq!(matrix3.shape(), (2, 2));
    /// ```
    pub fn from_triplets(
        rows: usize,
        cols: usize,
        triplets: &[(usize, usize, T)],
    ) -> Result<Self, SparseMatrixError> {
        let mut processed_triplets = Vec::with_capacity(triplets.len());

        // 1. Validate and filter out zero-value triplets initially
        for (r, c, v) in triplets.iter() {
            if *r >= rows {
                return Err(SparseMatrixError::IndexOutOfBounds(*r, rows));
            }
            if *c >= cols {
                return Err(SparseMatrixError::IndexOutOfBounds(*c, cols));
            }
            if *v != T::zero() {
                // Only include non-zero values
                processed_triplets.push((*r, *c, *v));
            }
        }

        // 2. Sort triplets by row, then by column
        processed_triplets.sort_unstable_by_key(|&(r, c, _)| (r, c));

        // 3. Aggregate duplicates and build final lists
        let mut final_col_indices = Vec::new();
        let mut final_values = Vec::new();
        let mut nnz_per_row = vec![0; rows]; // To count non-zeros per row temporarily

        if processed_triplets.is_empty() {
            return Ok(Self {
                row_indices: vec![0; rows + 1],
                col_indices: final_col_indices,
                values: final_values,
                shape: (rows, cols),
            });
        }

        let mut iter = processed_triplets.into_iter().peekable();

        while let Some((r, c, mut v)) = iter.next() {
            // Sum duplicate entries
            while iter
                .peek()
                .is_some_and(|&(next_r, next_c, _)| next_r == r && next_c == c)
            {
                v = v + iter.next().unwrap().2;
            }

            if v != T::zero() {
                // Only add if the summed value is not zero
                final_col_indices.push(c);
                final_values.push(v);
                nnz_per_row[r] += 1; // Count non-zero in this row
            }
        }

        // Convert counts to cumulative sum for row_indices
        let mut actual_row_indices = vec![0; rows + 1];
        for i in 0..rows {
            actual_row_indices[i + 1] = actual_row_indices[i] + nnz_per_row[i];
        }

        Ok(Self {
            row_indices: actual_row_indices,
            col_indices: final_col_indices,
            values: final_values,
            shape: (rows, cols),
        })
    }
}

impl<T> CsrMatrix<T>
where
    T: Clone + PartialEq + std::ops::Add<Output = T>,
{
    /// Creates a new `CsrMatrix` from a list of `(row, col, value)` triplets, using an explicit zero value.
    ///
    /// This method is similar to `from_triplets`, but instead of using `T::zero()`, it uses the provided
    /// `zero` value to determine which elements should be considered "zero" (and thus excluded from the sparse structure).
    /// This is useful for types that do not implement the `Zero` trait or when a different "zero" context is needed.
    ///
    /// # Arguments
    /// * `rows` - The number of rows in the matrix.
    /// * `cols` - The number of columns in the matrix.
    /// * `triplets` - A slice of `(row_idx, col_idx, value)` tuples.
    /// * `zero` - The value to treat as zero.
    ///
    /// # Errors
    /// Returns `SparseMatrixError::IndexOutOfBounds` if any triplet's indices
    /// are outside the specified matrix dimensions.
    pub fn from_triplets_with_zero(
        rows: usize,
        cols: usize,
        triplets: &[(usize, usize, T)],
        zero: T,
    ) -> Result<Self, SparseMatrixError> {
        let mut processed_triplets = Vec::with_capacity(triplets.len());

        // 1. Validate and filter out zero-value triplets initially
        for (r, c, v) in triplets.iter() {
            if *r >= rows {
                return Err(SparseMatrixError::IndexOutOfBounds(*r, rows));
            }
            if *c >= cols {
                return Err(SparseMatrixError::IndexOutOfBounds(*c, cols));
            }
            if *v != zero {
                // Only include non-zero values
                processed_triplets.push((*r, *c, v.clone()));
            }
        }

        // 2. Sort triplets by row, then by column
        processed_triplets.sort_unstable_by_key(|&(r, c, _)| (r, c));

        // 3. Aggregate duplicates and build final lists
        let mut final_col_indices = Vec::new();
        let mut final_values = Vec::new();
        let mut nnz_per_row = vec![0; rows]; // To count non-zeros per row temporarily

        if processed_triplets.is_empty() {
            return Ok(Self {
                row_indices: vec![0; rows + 1],
                col_indices: final_col_indices,
                values: final_values,
                shape: (rows, cols),
            });
        }

        let mut iter = processed_triplets.into_iter().peekable();

        while let Some((r, c, mut v)) = iter.next() {
            // Sum duplicate entries
            while iter
                .peek()
                .is_some_and(|&(next_r, next_c, _)| next_r == r && next_c == c)
            {
                v = v + iter.next().unwrap().2;
            }

            if v != zero {
                // Only add if the summed value is not zero
                final_col_indices.push(c);
                final_values.push(v);
                nnz_per_row[r] += 1; // Count non-zero in this row
            }
        }

        // Convert counts to cumulative sum for row_indices
        let mut actual_row_indices = vec![0; rows + 1];
        for i in 0..rows {
            actual_row_indices[i + 1] = actual_row_indices[i] + nnz_per_row[i];
        }

        Ok(Self {
            row_indices: actual_row_indices,
            col_indices: final_col_indices,
            values: final_values,
            shape: (rows, cols),
        })
    }

    /// Performs matrix addition with an explicit zero value: \( C = A + B \).
    ///
    /// This method allows adding matrices of types that do not implement `Zero`,
    /// provided an explicit zero value is given for sparsity checks.
    ///
    /// # Arguments
    /// * `other` - The matrix to add.
    /// * `zero` - The value to treat as zero.
    pub fn add_with_zero(&self, other: &Self, zero: T) -> Result<Self, SparseMatrixError>
    where
        T: std::ops::Add<Output = T>,
    {
        self.add_matrix_with_zero_impl(other, zero)
    }
}
