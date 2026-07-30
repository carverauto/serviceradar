/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::Tensor;
use crate::{CausalTensor, CausalTensorError};
use deep_causality_algebra::RealField;
use deep_causality_num::Zero;
use std::iter::Sum;
use std::ops::{Add, Div, Mul};

impl<T> CausalTensor<T>
where
    T: Clone + Default + PartialOrd,
{
    pub(in crate::types::causal_tensor) fn norm_l2_impl(&self) -> T
    where
        T: RealField + Zero + Sum + Copy,
    {
        let sum_sq: T = self.data.iter().map(|&x| x * x).sum();

        sum_sq.sqrt()
    }

    pub(in crate::types::causal_tensor) fn norm_sq_impl(&self) -> T
    where
        T: RealField + Zero + Sum + Copy + Mul,
    {
        self.data.iter().map(|&x| x * x).sum()
    }

    pub(in crate::types::causal_tensor) fn sum_axes_impl(
        &self,
        axes: &[usize],
    ) -> Result<Self, CausalTensorError>
    where
        T: Add<T, Output = T>,
    {
        // Check for invalid axes first.
        for &axis in axes {
            if axis >= self.num_dim() {
                return Err(CausalTensorError::AxisOutOfBounds);
            }
        }

        // Special case: sum all elements to a scalar tensor. This works for empty tensors too.
        if axes.is_empty() {
            let total_sum = self
                .data
                .iter()
                .fold(T::default(), |acc, x| acc + x.clone());
            // A scalar tensor has an empty shape `[]` but contains one data element.
            return CausalTensor::new(vec![total_sum], vec![]);
        }

        if self.data.is_empty() {
            let mut result_shape = Vec::new();
            for (i, &dim) in self.shape.iter().enumerate() {
                if !axes.contains(&i) {
                    result_shape.push(dim);
                }
            }
            // The resulting tensor should be filled with the identity element (0).
            return Ok(CausalTensor::full(&result_shape, T::default()));
        }

        // Determine the shape of the output tensor by filtering out the summed axes.
        let mut result_shape = Vec::new();
        for (i, &dim) in self.shape.iter().enumerate() {
            if !axes.contains(&i) {
                result_shape.push(dim);
            }
        }

        // Create the result tensor, initialized to zeros.
        let mut result_tensor = CausalTensor::full(&result_shape, T::default());

        // Iterate through all multi-dimensional indices of the *source* tensor.
        let mut current_index = vec![0; self.num_dim()];
        for i in 0..self.len() {
            // Get the value at the current flat index.
            let value = self.data[i].clone();

            // Map the source index to the destination index by removing axis components.
            let mut result_index = Vec::new();
            for (axis_idx, &idx_val) in current_index.iter().enumerate() {
                if !axes.contains(&axis_idx) {
                    result_index.push(idx_val);
                }
            }

            // Add the value to the corresponding position in the result tensor.
            if let Some(res_val) = result_tensor.get_mut(&result_index) {
                *res_val = res_val.clone() + value;
            }

            // --- Increment the multi-dimensional index ---
            // This logic effectively emulates a nested for-loop over all dimensions.
            for j in (0..self.num_dim()).rev() {
                current_index[j] += 1;
                if current_index[j] < self.shape[j] {
                    break;
                }
                current_index[j] = 0;
            }
        }

        Ok(result_tensor)
    }

    pub(in crate::types::causal_tensor) fn mean_axes_impl(
        &self,
        axes: &[usize],
    ) -> Result<Self, CausalTensorError>
    where
        T: Div<T, Output = T> + From<u32> + Add<T, Output = T>,
    {
        // First, calculate the sum.
        let mut sum_tensor = self.sum_axes(axes)?;

        // Calculate the number of elements we summed over.
        let count = if axes.is_empty() {
            self.len()
        } else {
            let mut c: usize = 1;
            for &axis in axes {
                if axis >= self.num_dim() {
                    return Err(CausalTensorError::AxisOutOfBounds);
                }
                c *= self.shape[axis];
            }
            c
        };

        if count == 0 {
            // Avoid division by zero. This can happen with an empty tensor or a zero-sized dimension.
            return Err(CausalTensorError::InvalidOperation);
        }

        // Perform element-wise division of the sum tensor by the count.
        let count_t: T = (count as u32).into(); // A reasonable conversion path
        for item in &mut sum_tensor.data {
            *item = item.clone() / count_t.clone();
        }

        Ok(sum_tensor)
    }

    pub(in crate::types::causal_tensor) fn arg_sort_impl(
        &self,
    ) -> Result<Vec<usize>, CausalTensorError> {
        if self.num_dim() != 1 {
            return Err(CausalTensorError::DimensionMismatch);
        }

        // Pre-emptively check for non-comparable values like NaN.
        // A value is not comparable if it is not equal to itself.
        for x in &self.data {
            if x.partial_cmp(x).is_none() {
                return Err(CausalTensorError::UnorderableValue);
            }
        }

        let mut indices: Vec<usize> = (0..self.len()).collect();

        // It is now safe to unwrap, as we have checked for non-comparable values.
        indices.sort_by(|&a, &b| self.data[a].partial_cmp(&self.data[b]).unwrap());

        Ok(indices)
    }
}
