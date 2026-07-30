/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::fmt;

/// Represents errors that can occur during sparse matrix operations.
#[derive(Debug, Clone, PartialEq, Eq)] // Added Clone, PartialEq, Eq for completeness
pub enum SparseMatrixError {
    ShapeMismatch((usize, usize), (usize, usize)),
    DimensionMismatch(usize, usize),
    IndexOutOfBounds(usize, usize),
    EmptyMatrix,
}

impl fmt::Display for SparseMatrixError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            SparseMatrixError::ShapeMismatch(left_shape, right_shape) => {
                write!(
                    f,
                    "Shape mismatch: Cannot perform operation on matrices with different shapes. Left: {:?}, Right: {:?}",
                    left_shape, right_shape
                )
            }
            SparseMatrixError::DimensionMismatch(left_cols, right_rows) => {
                write!(
                    f,
                    "Dimension mismatch: Incompatible dimensions for matrix multiplication. Left columns: {}, Right rows: {}",
                    left_cols, right_rows
                )
            }
            SparseMatrixError::IndexOutOfBounds(index, size) => {
                write!(
                    f,
                    "Index out of bounds: Index {} is out of bounds for dimension of size {}.",
                    index, size
                )
            }
            SparseMatrixError::EmptyMatrix => {
                write!(f, "Empty matrix: Operation not supported on empty matrix.")
            }
        }
    }
}

impl std::error::Error for SparseMatrixError {}
