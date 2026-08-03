/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError};

// Mostly used in inverse_impl
impl<T> CausalTensor<T> {
    /// Returns a reference to the element at the given 2D indices with bounds checking.
    ///
    /// # Errors
    /// Returns `CausalTensorError::IndexOutOfBounds` if `row` or `col` are out of bounds.
    #[inline]
    pub(crate) fn get_ref(&self, row: usize, col: usize) -> Result<&T, CausalTensorError> {
        if self.num_dim() != 2 || row >= self.shape[0] || col >= self.shape[1] {
            return Err(CausalTensorError::IndexOutOfBounds);
        }
        let flat_index = row * self.strides[0] + col * self.strides[1];
        Ok(&self.data[flat_index])
    }

    /// Sets the element at the given 2D indices with bounds checking.
    ///
    /// # Errors
    /// Returns `CausalTensorError::IndexOutOfBounds` if `row` or `col` are out of bounds.
    #[inline]
    pub(crate) fn set(
        &mut self,
        row: usize,
        col: usize,
        value: T,
    ) -> Result<(), CausalTensorError> {
        if self.num_dim() != 2 || row >= self.shape[0] || col >= self.shape[1] {
            return Err(CausalTensorError::IndexOutOfBounds);
        }
        let flat_index = row * self.strides[0] + col * self.strides[1];
        self.data[flat_index] = value;
        Ok(())
    }
}
