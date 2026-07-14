/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Struct to hold the parameters for a Uniform distribution.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UniformDistributionParams {
    pub low: f64,
    pub high: f64,
}

impl UniformDistributionParams {
    /// Creates a new `UniformDistributionParams` instance.
    ///
    /// # Arguments
    ///
    /// * `low` - The lower bound of the uniform distribution.
    /// * `high` - The upper bound of the uniform distribution.
    ///
    /// # Returns
    ///
    /// A new `UniformDistributionParams` instance.
    pub fn new(low: f64, high: f64) -> Self {
        Self { low, high }
    }
}

impl std::fmt::Display for UniformDistributionParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "UniformDistributionParams {{ low: {:.4} , high: {:.4} }}",
            self.low, self.high
        )
    }
}
