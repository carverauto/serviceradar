/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_algebra::Ring;
use deep_causality_num::One;

impl<T> CsrMatrix<T>
where
    T: Ring + One + Copy + Default + PartialEq,
{
    /// Creates an identity matrix of size `n × n`.
    ///
    /// # Arguments
    /// * `size` - The dimension of the square identity matrix
    ///
    /// # Returns
    /// An identity matrix where `I[i,i] = 1` and `I[i,j] = 0` for `i != j`.
    pub fn one(size: usize) -> Self {
        let mut row_indices = vec![0; size + 1];
        let mut col_indices = Vec::with_capacity(size);
        let mut values = Vec::with_capacity(size);

        for i in 0..size {
            col_indices.push(i);
            values.push(T::one());
            row_indices[i + 1] = i + 1;
        }

        Self {
            row_indices,
            col_indices,
            values,
            shape: (size, size),
        }
    }

    /// Matrix multiplication (panics on dimension mismatch).
    ///
    /// Computes `self * rhs` using sparse matrix multiplication.
    ///
    /// # Panics
    /// Panics if `self.cols != rhs.rows`.
    pub fn mul(&self, rhs: &Self) -> Self {
        self.mat_mult_impl(rhs)
            .expect("CsrMatrix dimension mismatch in mul")
    }
}
