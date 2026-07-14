/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use core::fmt;
use std::error::Error;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NormalDistributionError {
    /// The mean value is too small (log-normal samples must be positive)
    MeanTooSmall,
    /// The standard deviation or other dispersion parameter is not finite.
    BadVariance,
}

impl Error for NormalDistributionError {}

impl fmt::Display for NormalDistributionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            NormalDistributionError::MeanTooSmall => "mean < 0 or NaN in log-normal distribution",
            NormalDistributionError::BadVariance => {
                "variation parameter is non-finite in (log)normal distribution"
            }
        })
    }
}
