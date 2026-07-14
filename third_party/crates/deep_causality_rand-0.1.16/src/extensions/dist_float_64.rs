/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::extensions::dist_float_common::{open_closed_unit, open_unit, standard_unit};
use crate::{Distribution, Open01, OpenClosed01, Rng, StandardUniform};

// f64 carries 52 mantissa bits; the multiply-based kernels use 53 bits of precision (52 + 1)
// drawn from a u64, the transmute-based Open01 kernel uses 52.
impl Distribution<f64> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f64 {
        let scale = 1.0 / ((1_u64 << 53) as f64);
        standard_unit::<f64, R>(rng, scale, 64 - 53)
    }
}

impl Distribution<f64> for OpenClosed01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f64 {
        let scale = 1.0 / ((1_u64 << 53) as f64);
        open_closed_unit::<f64, R>(rng, scale, 64 - 53)
    }
}

impl Distribution<f64> for Open01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f64 {
        open_unit::<f64, R>(rng, 64 - 52, 1.0 - f64::EPSILON / 2.0)
    }
}
