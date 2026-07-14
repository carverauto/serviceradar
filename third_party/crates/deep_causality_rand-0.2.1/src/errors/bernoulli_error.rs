/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use core::fmt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BernoulliDistributionError {
    /// `p < 0` or `p > 1`.
    InvalidProbability,
}

impl std::error::Error for BernoulliDistributionError {}

impl fmt::Display for BernoulliDistributionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            BernoulliDistributionError::InvalidProbability => {
                "p is outside [0, 1] in Bernoulli distribution"
            }
        })
    }
}
