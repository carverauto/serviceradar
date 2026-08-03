/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensorError;

mod algebra;
mod api;
mod arithmetic;
mod display;
mod from;
mod getters;
mod ops;

pub(crate) use ops::tensor_eigen::sym_eig;
mod to;

pub use ops::tensor_ein_sum::ein_sum_op::{EinSumAST, EinSumOp};

/// `CausalTensor` is a low-dimensional (up to ~5-25 dimensions recommended) tensor
/// backed by a single, contiguous `Vec<T>`. It uses a stride-based memory layout
/// for efficient, cache-friendly access and manipulation.
///
/// **Operation Semantics:**
/// Operations on `CausalTensor` generally fall into two categories regarding data handling:
///
/// 1.  **Metadata-Only Operations (e.g., `reshape`, `permute_axes`, `ravel`):**
///     These operations create a new `CausalTensor` instance but do *not* physically reorder
///     or reallocate the underlying data in memory. Instead, they create a *cloned* copy of the
///     original flat data and only modify the `shape` and `strides` metadata to provide a new
///     logical view of the data. This makes them very efficient as they avoid large data movements.
///
/// 2.  **Data-Copying Operations (e.g., `slice`, binary operations like `add`, `sub`, `mul`, `div`,
///     reduction operations like `sum_axes`, `mean_axes`):**
///     These operations create a new `CausalTensor` instance with newly allocated data.
///     The data is either a subset of the original, a transformation of the original, or a result
///     of combining multiple tensors. These operations involve iterating through and copying/computing
///     values into a new `Vec<T>`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CausalTensor<T> {
    pub(crate) data: Vec<T>,
    shape: Vec<usize>,
    strides: Vec<usize>,
}

impl<T> CausalTensor<T> {
    ///
    /// This constructor validates that the total number of elements implied by the `shape`
    /// matches the length of the provided `data` vector. It also internally calculates
    /// the strides for efficient memory access based on the given `shape`.
    ///
    /// # Arguments
    ///
    /// * `data` - A `Vec<T>` containing the tensor's elements in row-major order.
    /// * `shape` - A `Vec<usize>` defining the dimensions of the tensor.
    ///
    /// # Returns
    ///
    /// A `Result` which is:
    /// * `Ok(Self)` if the `data` length matches the `shape`'s total elements.
    /// * `Err(CausalTensorError::ShapeMismatch)` if the lengths do not match.
    pub fn new(data: Vec<T>, shape: Vec<usize>) -> Result<Self, CausalTensorError> {
        let expected_len: usize = shape.iter().product();
        if data.len() != expected_len {
            return Err(CausalTensorError::ShapeMismatch);
        }

        // Calculate strides internally, which is the core safety improvement.
        let mut strides = vec![0; shape.len()];
        if !shape.is_empty() {
            let mut current_stride = 1;
            // Iterate from the last dimension to the first
            for i in (0..shape.len()).rev() {
                strides[i] = current_stride;
                current_stride *= shape[i];
            }
        }

        Ok(Self {
            data,
            shape,
            strides,
        })
    }

    /// Creates a tensor from a function applied to each index.
    ///
    /// # Arguments
    /// * `shape` - Dimensions of the tensor
    /// * `f` - Function mapping indices to values
    pub fn from_shape_fn<F>(shape: &[usize], mut f: F) -> Self
    where
        F: FnMut(&[usize]) -> T,
    {
        let total_elements: usize = shape.iter().product();
        let mut data = Vec::with_capacity(total_elements);

        if total_elements == 0 {
            return Self::from_vec_and_shape_unchecked(data, shape);
        }

        let rank = shape.len();
        let mut index = vec![0; rank];

        for _ in 0..total_elements {
            data.push(f(&index));

            // Increment index in row-major order
            for i in (0..rank).rev() {
                index[i] += 1;
                if index[i] < shape[i] {
                    break;
                }
                index[i] = 0;
            }
        }

        Self::from_vec_and_shape_unchecked(data, shape)
    }

    /// Internal constructor that calculates strides.
    /// Call only when shape is known to be valid.
    pub(super) fn from_vec_and_shape_unchecked(data: Vec<T>, shape: &[usize]) -> Self {
        let mut strides = vec![0; shape.len()];
        if !shape.is_empty() {
            let mut current_stride = 1;
            for i in (0..shape.len()).rev() {
                strides[i] = current_stride;
                current_stride *= shape[i];
            }
        }
        Self {
            data,
            shape: shape.to_vec(),
            strides,
        }
    }
}

impl<T> CausalTensor<T>
where
    T: Clone,
{
    /// Creates a tensor from a slice (infallible, clones data).
    pub fn from_slice(data: &[T], shape: &[usize]) -> Self {
        Self::new(data.to_vec(), shape.to_vec()).unwrap()
    }
}

impl<T> CausalTensor<T>
where
    T: Clone + Default,
{
    /// Creates a tensor of zeros with the given shape.
    pub fn zeros(shape: &[usize]) -> Self {
        let total_elements: usize = shape.iter().product();
        let data = vec![T::default(); total_elements];
        Self::from_vec_and_shape_unchecked(data, shape)
    }
}
