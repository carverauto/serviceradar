/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod standard_normal;

use crate::{Distribution, NormalDistributionError, Rng, StandardNormal};
use deep_causality_num::Float;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Normal<F>
where
    F: Float,
    StandardNormal: Distribution<F>,
{
    mean: F,
    std_dev: F,
}

impl<F> Normal<F>
where
    F: Float,
    StandardNormal: Distribution<F>,
{
    /// Construct, from mean and standard deviation
    ///
    /// Parameters:
    ///
    /// -   mean (`μ`, unrestricted)
    /// -   standard deviation (`σ`, must be finite)
    #[inline]
    pub fn new(mean: F, std_dev: F) -> Result<Normal<F>, NormalDistributionError> {
        if !std_dev.is_finite() {
            return Err(NormalDistributionError::BadVariance);
        }
        Ok(Normal { mean, std_dev })
    }

    /// Construct, from mean and coefficient of variation
    ///
    /// Parameters:
    ///
    /// -   mean (`μ`, unrestricted)
    /// -   coefficient of variation (`cv = abs(σ / μ)`)
    #[inline]
    pub fn from_mean_cv(mean: F, cv: F) -> Result<Normal<F>, NormalDistributionError> {
        if !cv.is_finite() || cv < F::zero() {
            return Err(NormalDistributionError::BadVariance);
        }
        let std_dev = cv * mean;
        Ok(Normal { mean, std_dev })
    }

    /// Sample from a z-score
    #[inline]
    pub fn sample_from_zscore(&self, zscore: F) -> F {
        self.mean + self.std_dev * zscore
    }

    /// Returns the mean (`μ`) of the distribution.
    pub fn mean(&self) -> F {
        self.mean
    }

    /// Returns the standard deviation (`σ`) of the distribution.
    pub fn std_dev(&self) -> F {
        self.std_dev
    }
}

impl<F> Distribution<F> for Normal<F>
where
    F: Float,
    StandardNormal: Distribution<F>,
{
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> F {
        self.sample_from_zscore(rng.sample(StandardNormal))
    }
}
