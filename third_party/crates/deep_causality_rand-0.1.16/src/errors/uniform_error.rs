/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use core::fmt;
use std::error::Error;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UniformDistributionError {
    /// Input or range `high - low` is non-finite. Not relevant to integer types.
    NonFinite,
    /// Invalid range: low must be less than high
    InvalidRange,
    /// Empty range in uniform distribution
    EmptyRange,
}

impl Error for UniformDistributionError {}

impl fmt::Display for UniformDistributionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            UniformDistributionError::NonFinite => "Non-finite range in uniform distribution",
            UniformDistributionError::InvalidRange => "Invalid range: low must be less than high",
            UniformDistributionError::EmptyRange => "Empty range in uniform distribution",
        })
    }
}
