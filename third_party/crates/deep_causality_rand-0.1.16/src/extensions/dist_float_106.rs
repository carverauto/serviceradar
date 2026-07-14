/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Uniform distributions for `Float106` (double-double, ~106-bit mantissa).
//!
//! `Float106` is not a single-word IEEE float, so it does not share the bit-construction kernels in
//! `dist_float_common`. Instead a sample is composed from two independent 53-bit `f64` uniforms: a
//! high part in `[0, 1)` and a low part scaled by `2^-53`, giving a value on the full 106-bit grid.

use crate::{Distribution, Open01, OpenClosed01, Rng, StandardUniform};
use deep_causality_num::{Float106, One};

/// `2^-53`, exact in `f64` (a power of two), used to place the low 53 bits below the high part.
const SCALE_LO: f64 = 1.0 / ((1_u64 << 53) as f64);

/// A second independent 53-bit `f64` uniform, shifted into the low half (`× 2^-53`). The product is
/// exact (multiplication by a power of two), so it occupies bits 54..=106 with no rounding.
#[inline]
fn low_part<R: Rng + ?Sized>(rng: &mut R) -> Float106 {
    let lo: f64 = StandardUniform.sample(rng);
    Float106::from(lo * SCALE_LO)
}

impl Distribution<Float106> for StandardUniform {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Float106 {
        // [0, 1): a 53-bit high part in [0, 1) plus a 53-bit low part in [0, 2^-53).
        let hi: f64 = StandardUniform.sample(rng);
        Float106::from(hi) + low_part(rng)
    }
}

impl Distribution<Float106> for OpenClosed01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Float106 {
        // (0, 1] by reflecting a half-open [0, 1) sample: 1 - [0, 1) = (0, 1].
        let x: Float106 = StandardUniform.sample(rng);
        Float106::one() - x
    }
}

impl Distribution<Float106> for Open01 {
    fn sample<R: Rng + ?Sized>(&self, rng: &mut R) -> Float106 {
        // (0, 1): an Open01 f64 high part already lies in [2^-53, 1 - 2^-53]; adding the low part in
        // [0, 2^-53) keeps the result strictly inside (0, 1).
        let hi: f64 = Open01.sample(rng);
        Float106::from(hi) + low_part(rng)
    }
}
