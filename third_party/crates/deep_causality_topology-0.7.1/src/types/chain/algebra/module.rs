/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::chain::Chain;
use deep_causality_algebra::{Module, Ring};
use std::sync::Arc;

impl<T> Chain<T> {
    /// Scales the chain by a scalar.
    ///
    /// # Arguments
    /// * `scalar` - The scalar to multiply by.
    ///
    /// # Returns
    /// A new chain with all weights scaled.
    pub fn scale<S>(&self, scalar: S) -> Self
    where
        T: Module<S> + Copy,
        S: Ring + Copy,
    {
        let weights = self.weights.scale(scalar);
        Self {
            complex: Arc::clone(&self.complex),
            grade: self.grade,
            weights,
        }
    }
}
