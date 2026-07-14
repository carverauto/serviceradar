/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::extensions::dist_float_common::{open_closed_unit, open_unit, standard_unit};
use crate::{Distribution, Open01, OpenClosed01, Rng, StandardUniform};

// f32 carries 23 mantissa bits; the multiply-based kernels use 24 bits of precision (23 + 1)
// drawn from a u32, the transmute-based Open01 kernel uses 23.
impl Distribution<f32> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f32 {
        let scale = 1.0 / ((1_u32 << 24) as f32);
        standard_unit::<f32, R>(rng, scale, 32 - 24)
    }
}

impl Distribution<f32> for OpenClosed01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f32 {
        let scale = 1.0 / ((1_u32 << 24) as f32);
        open_closed_unit::<f32, R>(rng, scale, 32 - 24)
    }
}

impl Distribution<f32> for Open01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> f32 {
        open_unit::<f32, R>(rng, 32 - 23, 1.0 - f32::EPSILON / 2.0)
    }
}
