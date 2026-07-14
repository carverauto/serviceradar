/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::distr::uniform::{RandFloat, UniformFloat};
use crate::{Distribution, Rng, SampleUniform, StandardUniform};
use deep_causality_num::Float106;

impl RandFloat for Float106 {
    fn rand_float_gen<R: Rng + ?Sized>(rng: &mut R) -> Float106 {
        // Reuse the double-double `[0, 1)` construction from the extensions
        // layer (`StandardUniform: Distribution<Float106>`): a 53-bit high part plus
        // an independent 53-bit low part scaled by 2^-53, i.e. ~106-bit entropy — not
        // an f64 draw widened to double-double.
        StandardUniform.sample(rng)
    }
}

impl SampleUniform for Float106 {
    type Sampler = UniformFloat<Float106>;
}
