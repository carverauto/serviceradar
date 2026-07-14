/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub mod standard_uniform;
mod uniform_f32;
mod uniform_f64;
pub mod uniform_u32;
mod uniform_u64;
mod uniform_usize;

use crate::{
    Distribution, Rng, SampleBorrow, SampleUniform, UniformDistributionError, UniformSampler,
};
use deep_causality_num::Float;
use std::fmt::Debug;

#[derive(Debug, Copy, Clone)]
pub struct Uniform<X: SampleUniform>(X::Sampler);

impl<X: SampleUniform> Uniform<X> {
    /// Create a new `Uniform` instance, which samples uniformly from the half
    /// open range `[low, high)` (excluding `high`).
    ///
    /// For discrete types (e.g. integers), samples will always be strictly less
    /// than `high`. For (approximations of) continuous types (e.g. `f32`, `f64`),
    /// samples may equal `high` due to loss of precision but may not be
    /// greater than `high`.
    ///
    /// Fails if `low >= high`, or if `low`, `high` or the range `high - low` is
    /// non-finite. In release mode, only the range is checked.
    pub fn new<B1, B2>(low: B1, high: B2) -> Result<Uniform<X>, UniformDistributionError>
    where
        B1: SampleBorrow<X> + Sized,
        B2: SampleBorrow<X> + Sized,
    {
        X::Sampler::new(low, high).map(Uniform)
    }

    /// Create a new `Uniform` instance, which samples uniformly from the closed
    /// range `[low, high]` (inclusive).
    ///
    /// Fails if `low > high`, or if `low`, `high` or the range `high - low` is
    /// non-finite. In release mode, only the range is checked.
    pub fn new_inclusive<B1, B2>(low: B1, high: B2) -> Result<Uniform<X>, UniformDistributionError>
    where
        B1: SampleBorrow<X> + Sized,
        B2: SampleBorrow<X> + Sized,
    {
        X::Sampler::new_inclusive(low, high).map(Uniform)
    }
}

impl<X: SampleUniform> Distribution<X> for Uniform<X> {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> X {
        self.0.sample(rng)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct UniformFloat<F: Float> {
    low: F,
    scale: F,
}

// Helper trait to abstract the generation of a random float in [0, 1)
pub(crate) trait RandFloat: Sized {
    fn rand_float_gen<R: Rng + ?Sized>(rng: &mut R) -> Self;
}

impl<F> UniformSampler for UniformFloat<F>
where
    F: Float + RandFloat + Debug,
{
    type X = F;

    fn new<B1, B2>(low_b: B1, high_b: B2) -> Result<Self, UniformDistributionError>
    where
        B1: SampleBorrow<Self::X> + Sized,
        B2: SampleBorrow<Self::X> + Sized,
    {
        let low = *low_b.borrow();
        let high = *high_b.borrow();
        if !(low.is_finite() && high.is_finite()) {
            return Err(UniformDistributionError::NonFinite);
        }
        if low >= high {
            return Err(UniformDistributionError::EmptyRange);
        }
        let scale = high - low;
        if !scale.is_finite() {
            return Err(UniformDistributionError::NonFinite);
        }
        Ok(UniformFloat { low, scale })
    }

    fn new_inclusive<B1, B2>(low_b: B1, high_b: B2) -> Result<Self, UniformDistributionError>
    where
        B1: SampleBorrow<Self::X> + Sized,
        B2: SampleBorrow<Self::X> + Sized,
    {
        let low = *low_b.borrow();
        let high = *high_b.borrow();
        if !(low.is_finite() && high.is_finite()) {
            return Err(UniformDistributionError::NonFinite);
        }
        if low > high {
            return Err(UniformDistributionError::EmptyRange);
        }

        let max_rand = F::one() - F::epsilon();
        let scale = (high - low) / max_rand;
        if !scale.is_finite() {
            return Err(UniformDistributionError::NonFinite);
        }

        Ok(UniformFloat { low, scale })
    }

    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Self::X {
        let value0_1 = F::rand_float_gen(rng);
        value0_1 * self.scale + self.low
    }
}
