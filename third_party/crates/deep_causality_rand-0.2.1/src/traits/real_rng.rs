/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::distr::uniform::RandFloat;
use crate::{Distribution, Rng, SampleUniform, StandardNormal};
use deep_causality_algebra::RealField;

/// Capability bound bundling the standard random draws for a real scalar.
///
/// `RealRng` lets precision-generic downstream code (for example
/// `deep_causality_uncertain`) thread a single `R: RealRng` bound instead of
/// repeating `RealField + SampleUniform` together with a `StandardNormal:
/// Distribution<Self>` clause — and, crucially, **without naming `Float`**, so the
/// num-crate "precision is a type parameter" mechanism stays intact: a new float
/// type gains `RealRng` automatically once it has the num-crate `Float` impl and the
/// rand-crate per-type sampling seam, and downstream code is untouched.
///
/// Blanket-implemented for every real scalar carrying the per-type seam
/// (`f32`, `f64`, `Float106`).
pub trait RealRng: RealField + Sized {
    /// A draw from the standard normal distribution `N(0, 1)`, at `Self` precision.
    fn sample_standard_normal<G: Rng + ?Sized>(rng: &mut G) -> Self;

    /// A uniform draw on `[0, 1)`, at `Self` precision.
    fn sample_uniform_01<G: Rng + ?Sized>(rng: &mut G) -> Self;
}

impl<T> RealRng for T
where
    T: RealField + SampleUniform + RandFloat,
    StandardNormal: Distribution<T>,
{
    #[inline]
    fn sample_standard_normal<G: Rng + ?Sized>(rng: &mut G) -> Self {
        rng.sample(StandardNormal)
    }

    #[inline]
    fn sample_uniform_01<G: Rng + ?Sized>(rng: &mut G) -> Self {
        T::rand_float_gen(rng)
    }
}
