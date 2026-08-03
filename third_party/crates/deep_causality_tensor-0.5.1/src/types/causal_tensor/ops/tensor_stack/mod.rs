/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CausalTensor, CausalTensorError};
use std::ops::{Add, Mul};

impl<T> CausalTensor<T>
where
    T: Clone + Default + PartialOrd + Add<Output = T> + Mul<Output = T>,
{
    pub(crate) fn stack_impl(
        tensors: &[CausalTensor<T>],
        axis: usize,
    ) -> Result<CausalTensor<T>, CausalTensorError> {
        if tensors.is_empty() {
            return Err(CausalTensorError::EmptyTensor);
        }

        let first_shape = tensors[0].shape();
        if axis > first_shape.len() {
            return Err(CausalTensorError::AxisOutOfBounds);
        }

        for tensor in tensors.iter().skip(1) {
            if tensor.shape() != first_shape {
                return Err(CausalTensorError::ShapeMismatch);
            }
        }

        let mut result_shape = first_shape.to_vec();
        result_shape.insert(axis, tensors.len());
        let result_len: usize = result_shape.iter().product();
        let mut result_data = Vec::with_capacity(result_len);

        let mut current_index = vec![0; result_shape.len()];
        for _ in 0..result_len {
            let slice_index = current_index[axis];
            let mut source_index = current_index.clone();
            source_index.remove(axis);

            let value = tensors[slice_index]
                .get(&source_index)
                .expect("Internal logic error");
            result_data.push(value.clone());

            for j in (0..result_shape.len()).rev() {
                current_index[j] += 1;
                if current_index[j] < result_shape[j] {
                    break;
                }
                current_index[j] = 0;
            }
        }

        CausalTensor::new(result_data, result_shape)
    }
}
