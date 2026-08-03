/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalTensor, CausalTensorError, Tensor};

impl<T> CausalTensor<T>
where
    T: Clone,
{
    /// Quantizes a physical axis of length `2^levels` into `levels` binary axes, in big-endian
    /// (coarse-to-fine) order — the QTT (quantized tensor-train) encoding lever for smooth /
    /// multi-scale fields.
    ///
    /// This is metadata-only (a reshape): because the data is row-major, splitting an axis of size
    /// `2^levels` into `levels` axes of size 2 in big-endian order *is* a reshape.
    ///
    /// # Errors
    /// - [`CausalTensorError::AxisOutOfBounds`] if `axis` is out of range.
    /// - [`CausalTensorError::InvalidParameter`] if `levels == 0` or the axis length is not
    ///   `2^levels`.
    pub fn quantize_axis(&self, axis: usize, levels: usize) -> Result<Self, CausalTensorError> {
        let shape = self.shape();
        if axis >= shape.len() {
            return Err(CausalTensorError::AxisOutOfBounds);
        }
        if levels == 0 || levels >= usize::BITS as usize || (1usize << levels) != shape[axis] {
            return Err(CausalTensorError::InvalidParameter(format!(
                "axis {axis} has length {}, which is not 2^{levels}",
                shape[axis]
            )));
        }
        let mut new_shape = Vec::with_capacity(shape.len() + levels - 1);
        new_shape.extend_from_slice(&shape[..axis]);
        new_shape.extend(core::iter::repeat_n(2usize, levels));
        new_shape.extend_from_slice(&shape[axis + 1..]);
        self.reshape(&new_shape)
    }

    /// Inverse of [`quantize_axis`](CausalTensor::quantize_axis): merges `levels` consecutive binary
    /// axes starting at `axis` back into one axis of length `2^levels`.
    ///
    /// # Errors
    /// - [`CausalTensorError::AxisOutOfBounds`] if the binary axis block is out of range.
    /// - [`CausalTensorError::InvalidParameter`] if `levels == 0` or any of the merged axes is not
    ///   of length 2.
    pub fn merge_binary_axes(&self, axis: usize, levels: usize) -> Result<Self, CausalTensorError> {
        let shape = self.shape();
        if levels == 0 || levels >= usize::BITS as usize {
            return Err(CausalTensorError::InvalidParameter(
                "levels must be in 1..usize::BITS".to_string(),
            ));
        }
        if axis + levels > shape.len() {
            return Err(CausalTensorError::AxisOutOfBounds);
        }
        if shape[axis..axis + levels].iter().any(|&d| d != 2) {
            return Err(CausalTensorError::InvalidParameter(
                "merged axes must all have length 2".to_string(),
            ));
        }
        let mut new_shape = Vec::with_capacity(shape.len() - levels + 1);
        new_shape.extend_from_slice(&shape[..axis]);
        new_shape.push(1usize << levels);
        new_shape.extend_from_slice(&shape[axis + levels..]);
        self.reshape(&new_shape)
    }
}
