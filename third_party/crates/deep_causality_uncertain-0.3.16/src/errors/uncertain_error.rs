/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_rand::{
    BernoulliDistributionError, NormalDistributionError, UniformDistributionError,
};
use std::fmt;

/// Custom error type for the `deep_causality_uncertain` crate.
#[derive(Debug)]
pub enum UncertainError {
    /// An error originating from the underlying graph structure.
    GraphError(String),
    /// An error related to statistical confidence or hypothesis testing.
    ConfidenceError(String),
    /// An error indicating that an operation is not supported for a given type.
    UnsupportedTypeError(String),
    /// An error occurred creating a Bernoulli distribution, likely due to invalid parameters.
    BernoulliDistributionError(String),
    /// An error occurred creating a Normal , likely due to invalid parameters.
    NormalDistributionError(String),
    /// An error occurred creating a Uniform distribution, likely due to invalid parameters.
    UniformDistributionError(String),
    /// An error occurred during the sampling process.
    SamplingError(String),
    /// An error indicating that a probabilistic value failed to meet the required confidence threshold to be considered definitively present.
    PresenceError(String),
}

impl fmt::Display for UncertainError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            UncertainError::GraphError(msg) => write!(f, "Graph construction error: {}", msg),
            UncertainError::ConfidenceError(msg) => write!(f, "Confidence error: {}", msg),
            UncertainError::UnsupportedTypeError(msg) => write!(f, "Unsupported type: {}", msg),
            UncertainError::BernoulliDistributionError(msg) => {
                write!(f, "Bernoulli distribution error: {}", msg)
            }

            UncertainError::NormalDistributionError(msg) => {
                write!(f, "Normal distribution error: {}", msg)
            }
            UncertainError::UniformDistributionError(msg) => {
                write!(f, "Uniform distribution error: {}", msg)
            }
            UncertainError::SamplingError(msg) => write!(f, "Sampling error: {}", msg),
            UncertainError::PresenceError(msg) => write!(f, "Presence error: {}", msg),
        }
    }
}

impl std::error::Error for UncertainError {}

// Allow easy conversion from rand_distr errors into our custom error type.
impl From<UniformDistributionError> for UncertainError {
    fn from(err: UniformDistributionError) -> Self {
        UncertainError::UniformDistributionError(err.to_string())
    }
}

impl From<BernoulliDistributionError> for UncertainError {
    fn from(err: BernoulliDistributionError) -> Self {
        UncertainError::BernoulliDistributionError(err.to_string())
    }
}

impl From<NormalDistributionError> for UncertainError {
    fn from(err: NormalDistributionError) -> Self {
        UncertainError::NormalDistributionError(err.to_string())
    }
}
