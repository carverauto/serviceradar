/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CsrMatrix;
use deep_causality_algebra::{Module, Ring};

impl<T> CsrMatrix<T> {
    /// Scalar multiplication.
    ///
    /// # Arguments
    /// * `scalar` - The scalar to multiply by
    ///
    /// # Returns
    /// A new matrix where each element is multiplied by `scalar`.
    pub fn scale<S>(&self, scalar: S) -> Self
    where
        T: Module<S> + Copy,
        S: Ring + Copy,
    {
        // For CsrMatrix, scalar multiplication is element-wise
        // T: Module<S> implies T: Mul<S, Output = T>
        let new_values: Vec<T> = self.values.iter().map(|&v| v * scalar).collect();
        Self {
            row_indices: self.row_indices.clone(),
            col_indices: self.col_indices.clone(),
            values: new_values,
            shape: self.shape,
        }
    }
}
