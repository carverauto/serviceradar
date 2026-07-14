/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Struct to hold the parameters for a Normal (Gaussian) distribution, at precision `R`.
///
/// The struct itself is unbounded so `DistributionEnum<T>` instantiates cleanly for every
/// `T` (including `bool`, where the Normal variant is unused); the analytic bound lives on
/// the sampling path, not here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct NormalDistributionParams<R> {
    pub mean: R,
    pub std_dev: R,
}

impl<R> NormalDistributionParams<R> {
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
    pub fn new(mean: R, std_dev: R) -> Self {
        Self { mean, std_dev }
    }
}
impl<R: std::fmt::Display> std::fmt::Display for NormalDistributionParams<R> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "NormalDistributionParams {{ mean:  {:.4} , std_dev:  {:.4}  }}",
            self.mean, self.std_dev
        )
    }
}
