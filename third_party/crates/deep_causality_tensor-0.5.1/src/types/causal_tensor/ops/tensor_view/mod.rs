/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError};

impl<T> CausalTensor<T>
where
    T: Clone,
{
    pub(in crate::types::causal_tensor) fn slice_impl(
        &self,
        axis: usize,
        index: usize,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        // --- 1. Input Validation ---
        if axis >= self.num_dim() {
            return Err(CausalTensorError::AxisOutOfBounds);
        }
        if index >= self.shape()[axis] {
            // Using a specific error for this would be even better, but this is clear enough.
            return Err(CausalTensorError::AxisOutOfBounds);
        }

        // --- 2. Calculate the shape of the new, sliced tensor ---
        let mut new_shape: Vec<usize> = self.shape().to_vec();
        new_shape.remove(axis);

        let new_len: usize = new_shape.iter().product();
        let mut new_data = Vec::with_capacity(new_len);

        // --- 3. Iterate and copy the relevant data ---
        // This is a robust, safe way to iterate through all elements of the slice.
        let mut current_index = vec![0; self.num_dim()];
        for _ in 0..self.len() {
            // If the current multi-dimensional index is on the desired slice...
            if current_index[axis] == index {
                // ...get the value at that position and push it to our new data buffer.
                // .unwrap() is safe because we are iterating within the bounds of self.len().
                let flat_index = self.get_flat_index(&current_index).unwrap();
                new_data.push(self.as_slice()[flat_index].clone());
            }

            // Increment the multi-dimensional index to the next position.
            for j in (0..self.num_dim()).rev() {
                current_index[j] += 1;
                if current_index[j] < self.shape()[j] {
                    break;
                }
                current_index[j] = 0;
            }
        }

        // --- 4. Construct and return the new tensor ---
        CausalTensor::new(new_data, new_shape)
    }

    pub(in crate::types::causal_tensor) fn shifted_view_impl(&self, flat_index: usize) -> Self
    where
        T: Clone,
    {
        let len = self.data.len();
        let shift = flat_index % len; // Safety check

        // 1. Clone the data (Since we are currently owning)
        let mut new_data = self.data.clone();

        // 2. Rotate the vector
        // Rust's native rotate_left handles the wrapping logic efficiently.
        // [A, B, C, D].rotate_left(1) -> [B, C, D, A]
        // Now index 0 holds 'B', which was previously at index 1.
        new_data.rotate_left(shift);

        // 3. Return new Tensor (Shape and Strides remain identical)
        Self {
            data: new_data,
            shape: self.shape.clone(),
            strides: self.strides.clone(),
        }
    }
}
