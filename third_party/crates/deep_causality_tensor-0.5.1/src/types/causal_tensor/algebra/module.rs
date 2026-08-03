/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalTensor;
use deep_causality_algebra::{Module, Ring};

impl<T> CausalTensor<T> {
    /// Scales the tensor by a scalar value.
    pub fn scale<S>(&self, scalar: S) -> Self
    where
        T: Module<S> + Copy,
        S: Ring + Copy,
    {
        let data = self.data.iter().map(|v| *v * scalar).collect();
        Self::from_vec_and_shape_unchecked(data, self.shape())
    }
}
