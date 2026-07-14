/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{BernoulliParams, NormalDistributionParams, UncertainError, UniformDistributionParams};
use deep_causality_rand::{Bernoulli, Distribution, Normal, Rng, Uniform}; // Import all necessary traits and structs
use std::fmt::{Display, Formatter};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum DistributionEnum<T> {
    Point(T),
    Normal(NormalDistributionParams),
    Uniform(UniformDistributionParams),
    Bernoulli(BernoulliParams),
}

impl DistributionEnum<f64> {
    /// Samples a value from the distribution for `f64` types.
    ///
    /// # Arguments
    ///
    /// * `rng` - A mutable reference to a random number generator.
    ///
    /// # Returns
    ///
    /// A `Result` containing the sampled `f64` value or an `UncertainError` if the distribution type is unsupported.
    pub fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Result<f64, UncertainError> {
        match self {
            DistributionEnum::Point(v) => Ok(*v),
            DistributionEnum::Normal(params) => {
                let normal = Normal::new(params.mean, params.std_dev)
                    .map_err(|e| UncertainError::NormalDistributionError(e.to_string()))?;
                Ok(normal.sample(rng))
            }
            DistributionEnum::Uniform(params) => {
                let uniform = Uniform::new(params.low, params.high)
                    .map_err(|e| UncertainError::UniformDistributionError(e.to_string()))?;
                Ok(uniform.sample(rng))
            }
            _ => Err(UncertainError::UnsupportedTypeError(
                "Distribution does not produce f64".to_string(),
            )),
        }
    }
}

impl DistributionEnum<bool> {
    /// Samples a value from the distribution for `bool` types.
    ///
    /// # Arguments
    ///
    /// * `rng` - A mutable reference to a random number generator.
    ///
    /// # Returns
    ///
    /// A `Result` containing the sampled `bool` value or an `UncertainError` if the distribution type is unsupported.
    pub fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Result<bool, UncertainError> {
        match self {
            DistributionEnum::Point(v) => Ok(*v),
            DistributionEnum::Bernoulli(params) => {
                let bernoulli = Bernoulli::new(params.p)
                    .map_err(|e| UncertainError::BernoulliDistributionError(e.to_string()))?;
                Ok(bernoulli.sample(rng))
            }
            _ => Err(UncertainError::UnsupportedTypeError(
                "Distribution does not produce bool".to_string(),
            )),
        }
    }
}

impl<T> Display for DistributionEnum<T>
where
    T: Display,
{
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            DistributionEnum::Point(d) => write!(f, "Distribution: Point {{ D: {} }}", d),
            DistributionEnum::Normal(d) => write!(f, "Distribution: Normal {{ D: {} }}", d),
            DistributionEnum::Uniform(d) => write!(f, "Distribution: Uniform {{ D: {} }}", d),
            DistributionEnum::Bernoulli(d) => write!(f, "Distribution: Bernoulli {{ D: {} }}", d),
        }
    }
}
