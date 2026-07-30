/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_algebra::AbelianGroup;
use std::ops::Sub;

// AbelianGroup for CsrMatrix
impl<T> AbelianGroup for CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T> + Default + PartialEq,
{
    // Marker trait, no methods needed here.
}

impl<T> CsrMatrix<T>
where
    T: AbelianGroup + Copy + Default + PartialEq,
{
    /// Creates a zero matrix with the given shape.
    ///
    /// # Arguments
    /// * `rows` - Number of rows
    /// * `cols` - Number of columns
    ///
    /// # Returns
    /// A sparse matrix with all elements zero (empty CSR structure).
    pub fn zero(rows: usize, cols: usize) -> Self {
        Self {
            row_indices: vec![0; rows + 1],
            col_indices: Vec::new(),
            values: Vec::new(),
            shape: (rows, cols),
        }
    }

    /// Element-wise matrix addition (panics on shape mismatch).
    ///
    /// # Panics
    /// Panics if `self.shape != rhs.shape`.
    pub fn add(&self, rhs: &Self) -> Self {
        self.add_matrix_impl(rhs)
            .expect("CsrMatrix shape mismatch in add")
    }
}

impl<T> CsrMatrix<T>
where
    T: AbelianGroup + Copy + Sub<Output = T> + Default + PartialEq,
{
    /// Element-wise matrix subtraction (panics on shape mismatch).
    ///
    /// # Panics
    /// Panics if `self.shape != rhs.shape`.
    pub fn sub(&self, rhs: &Self) -> Self {
        self.sub_matrix_impl(rhs)
            .expect("CsrMatrix shape mismatch in sub")
    }
}

impl<T> CsrMatrix<T>
where
    T: AbelianGroup + Copy + std::ops::Neg<Output = T>,
{
    /// Element-wise negation.
    pub fn neg(&self) -> Self {
        Self {
            row_indices: self.row_indices.clone(),
            col_indices: self.col_indices.clone(),
            values: self.values.iter().map(|&v| -v).collect(),
            shape: self.shape,
        }
    }
}
