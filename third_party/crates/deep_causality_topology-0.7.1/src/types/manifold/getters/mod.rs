/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Getter methods for Manifold.
//! Getter methods for Manifold fields.

use crate::Manifold;
use crate::traits::chain_complex::ChainComplex;
use deep_causality_tensor::CausalTensor;

impl<K: ChainComplex, F> Manifold<K, F> {
    /// Returns a reference to the underlying chain complex.
    pub fn complex(&self) -> &K {
        &self.complex
    }

    /// Returns a reference to the tensor data.
    pub fn data(&self) -> &CausalTensor<F> {
        &self.data
    }

    /// Returns an optional reference to the metric.
    pub fn metric(&self) -> Option<&K::Metric> {
        self.metric.as_ref()
    }

    /// Returns the current cursor position.
    pub fn cursor(&self) -> usize {
        self.cursor
    }
}
