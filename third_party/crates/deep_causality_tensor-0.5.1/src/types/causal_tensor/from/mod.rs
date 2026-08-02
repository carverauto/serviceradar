/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;

impl<T: Clone> From<T> for CausalTensor<T> {
    /// Creates a scalar tensor (0-dimensional) from a single value.
    fn from(item: T) -> Self {
        CausalTensor::from_vec_and_shape_unchecked(vec![item], &[])
    }
}

impl<'a, T: Clone> From<&'a T> for CausalTensor<T> {
    /// Creates a scalar tensor (0-dimensional) from a reference to a single value.
    fn from(item: &'a T) -> Self {
        CausalTensor::from_vec_and_shape_unchecked(vec![item.clone()], &[])
    }
}

impl<'a, T: Clone> From<&'a CausalTensor<T>> for CausalTensor<T> {
    /// Creates a new `CausalTensor` by cloning an existing `CausalTensor` reference.
    fn from(item: &'a CausalTensor<T>) -> Self {
        item.clone()
    }
}
