/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalTensor, CausalTensorError};

impl<T> CausalTensor<T>
where
    T: Clone,
{
    pub(in crate::types::causal_tensor) fn reshape_impl(
        &self,
        new_shape: &[usize],
    ) -> Result<Self, CausalTensorError> {
        let new_len: usize = new_shape.iter().product();
        if new_len != self.len() {
            return Err(CausalTensorError::ShapeMismatch);
        }

        // If the tensor is contiguous (standard logical order), we can just clone.
        // If not (e.g. permuted), we must materialize the data in logical order first.
        let data = if self.is_contiguous() {
            self.data.clone()
        } else {
            // Materialize data in logical order

            // Revisiting the `from_shape_fn` implementation in `mod.rs`:
            // It iterates total_elements and maintains an `index` vec.
            let total_elements = self.len();
            let mut data = Vec::with_capacity(total_elements);
            let rank = self.num_dim();
            let mut index = vec![0; rank];

            for _ in 0..total_elements {
                // We need to handle error here, but get_ref returns Result.
                // Reshape signature is Result.
                if let Some(val) = self.get(&index) {
                    data.push(val.clone());
                } else {
                    // Should not match, verified by len check.
                    return Err(CausalTensorError::IndexOutOfBounds);
                }

                // Increment index
                if rank > 0 {
                    for j in (0..rank).rev() {
                        index[j] += 1;
                        if index[j] < self.shape[j] {
                            break;
                        }
                        index[j] = 0;
                    }
                }
            }
            data
        };

        Ok(Self::from_vec_and_shape_unchecked(data, new_shape))
    }

    fn is_contiguous(&self) -> bool {
        // Calculate expected standard strides
        let mut expected_strides = vec![0; self.shape.len()];
        if !self.shape.is_empty() {
            let mut current_stride = 1;
            for i in (0..self.shape.len()).rev() {
                expected_strides[i] = current_stride;
                current_stride *= self.shape[i];
            }
        }
        self.strides == expected_strides
    }

    pub(in crate::types::causal_tensor) fn ravel_impl(mut self) -> Self {
        let len = self.len();
        self.shape = vec![len];
        self.strides = vec![1];
        self
    }

    pub(in crate::types::causal_tensor) fn permute_axes_impl(
        &self,
        axes: &[usize],
    ) -> Result<Self, CausalTensorError> {
        if axes.len() != self.num_dim() {
            return Err(CausalTensorError::DimensionMismatch);
        }

        // Validate axes uniqueness and bounds
        let mut seen_axes = vec![false; self.num_dim()];
        for &axis in axes {
            if axis >= self.num_dim() || seen_axes[axis] {
                return Err(CausalTensorError::InvalidParameter(
                    "Invalid axes permutation".to_string(),
                ));
            }
            seen_axes[axis] = true;
        }

        let mut new_shape = Vec::with_capacity(self.num_dim());
        let mut new_strides = Vec::with_capacity(self.num_dim());

        for &axis in axes {
            new_shape.push(self.shape[axis]);
            // This creates a correct strided view of the original data.
            new_strides.push(self.strides[axis]);
        }

        Ok(Self {
            data: self.data.clone(),
            shape: new_shape,
            strides: new_strides,
        })
    }
}
