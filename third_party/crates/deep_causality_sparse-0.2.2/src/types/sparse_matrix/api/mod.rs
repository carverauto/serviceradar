/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CsrMatrix, SparseMatrixError};
use deep_causality_num::{One, Zero};
use std::ops::{Mul, Sub};

impl<T> CsrMatrix<T>
where
    T: Copy + Zero + PartialEq + Default,
{
    /// Performs matrix addition: \( C = A + B \).
    ///
    /// Given two matrices \( A \) (self) and \( B \) (other) of the same shape \( m \times n \),
    /// their sum \( C \) is a matrix of the same shape where each element \( C_{ij} \) is the
    /// sum of the corresponding elements in \( A \) and \( B \):
    /// \( C_{ij} = A_{ij} + B_{ij} \).
    ///
    /// Returns a new `CsrMatrix` representing the sum of the two matrices,
    /// or a `SparseMatrixError::ShapeMismatch` if their shapes are not compatible.
    ///
    /// # Arguments
    ///
    /// * `other` - The matrix to add.
    ///
    /// # Errors
    ///
    /// Returns `SparseMatrixError::ShapeMismatch` if the matrices have different dimensions.
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_sparse::CsrMatrix;
    ///
    /// let a = CsrMatrix::from_triplets(2, 2, &[(0, 0, 1.0), (1, 1, 2.0)]).unwrap();
    /// // A = [[1.0, 0.0], [0.0, 2.0]]
    ///
    /// let b = CsrMatrix::from_triplets(2, 2, &[(0, 1, 3.0), (1, 0, 4.0)]).unwrap();
    /// // B = [[0.0, 3.0], [4.0, 0.0]]
    ///
    /// let c = a.add_matrix(&b).unwrap();
    /// // C = A + B = [[1.0, 3.0], [4.0, 2.0]]
    ///
    /// assert_eq!(c.get_value_at(0, 0), 1.0);
    /// assert_eq!(c.get_value_at(0, 1), 3.0);
    /// assert_eq!(c.get_value_at(1, 0), 4.0);
    /// assert_eq!(c.get_value_at(1, 1), 2.0);
    /// ```
    pub fn add_matrix(&self, other: &Self) -> Result<Self, SparseMatrixError> {
        self.add_matrix_impl(other)
    }

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
    pub fn transpose(&self) -> Self {
        self.transpose_impl()
    }
}

impl<T> CsrMatrix<T>
where
    T: Copy + Sub<Output = T> + Zero + PartialEq + Default,
{
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
    pub fn sub_matrix(&self, other: &Self) -> Result<Self, SparseMatrixError> {
        self.sub_matrix_impl(other)
    }
}

impl<T> CsrMatrix<T>
where
    T: Copy + Mul<Output = T> + Zero + PartialEq + Default + One,
{
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
    pub fn scalar_mult(&self, scalar: T) -> Self {
        self.scalar_mult_impl(scalar)
    }

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
    /// ```
    pub fn vec_mult(&self, vector: &[T]) -> Result<Vec<T>, SparseMatrixError> {
        self.vec_mult_impl(vector)
    }

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
    pub fn mat_mult(&self, other: &Self) -> Result<Self, SparseMatrixError> {
        self.mat_mult_impl(other)
    }
}
