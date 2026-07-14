/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::distr::uniform::{RandFloat, UniformFloat};
use crate::{Rng, SampleUniform};
use deep_causality_num::IntoFloat;

impl RandFloat for f64 {
    fn rand_float_gen<R: Rng + ?Sized>(rng: &mut R) -> f64 {
        // 52 random bits, [0, 1) interval.
        let value1_2 = (rng.random::<u64>() >> (64 - 52)).into_float_with_exponent(0);
        value1_2 - 1.0
    }
}

impl SampleUniform for f64 {
    type Sampler = UniformFloat<f64>;
}
