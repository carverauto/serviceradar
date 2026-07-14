/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Struct to hold the parameters for a Normal (Gaussian) distribution.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormalDistributionParams {
    pub mean: f64,
    pub std_dev: f64,
}

impl NormalDistributionParams {
    /// Creates a new `NormalDistributionParams` instance.
    ///
    /// # Arguments
    ///
    /// * `mean` - The mean (μ) of the normal distribution.
    /// * `std_dev` - The standard deviation (σ) of the normal distribution.
    ///
    /// # Returns
    ///
    /// A new `NormalDistributionParams` instance.
    pub fn new(mean: f64, std_dev: f64) -> Self {
        Self { mean, std_dev }
    }
}
impl std::fmt::Display for NormalDistributionParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "NormalDistributionParams {{ mean:  {:.4} , std_dev:  {:.4}  }}",
            self.mean, self.std_dev
        )
    }
}
