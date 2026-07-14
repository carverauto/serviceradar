/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Struct to hold the parameters for a Bernoulli distribution.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BernoulliParams {
    pub p: f64, // probability of success
}

impl BernoulliParams {
    /// Creates a new `BernoulliParams` instance.
    ///
    /// # Arguments
    ///
    /// * `p` - The probability of success (must be between 0.0 and 1.0, inclusive).
    ///
    /// # Returns
    ///
    /// A new `BernoulliParams` instance.
    pub fn new(p: f64) -> Self {
        Self { p }
    }
}

impl std::fmt::Display for BernoulliParams {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "BernoulliParams {{ p: {:.2} }}", self.p)
    }
}
