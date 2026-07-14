/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Generic float-sampling kernels shared by the `f32` and `f64` distribution impls.
//!
//! The IEEE-754 layout differs per type (mantissa width, backing integer), so the per-type impls
//! supply those constants (`scale`, `shift`, the Open01 epsilon); the bit-construction logic lives
//! here once, generic over `deep_causality_num`'s float-bit traits. `Float106` does not use these
//! kernels — it is not a single-word IEEE float, so it composes two `f64` samples instead.

use crate::{Distribution, Rng, StandardUniform};
use core::ops::{Add, Mul, Shr, Sub};
use deep_causality_num::{FloatAsScalar, FloatFromInt, IntoFloat, One};

/// Multiply-based half-open `[0, 1)` kernel: draw the backing integer, keep the top `precision`
/// bits, and scale into the unit interval.
#[inline]
pub(crate) fn standard_unit<F, R>(rng: &mut R, scale: F, shift: u32) -> F
where
    F: FloatFromInt + FloatAsScalar + Mul<Output = F>,
    F::UInt: Shr<u32, Output = F::UInt>,
    StandardUniform: Distribution<F::UInt>,
    R: Rng + ?Sized,
{
    let value: F::UInt = StandardUniform.sample(rng);
    let value = value >> shift;
    F::splat(scale) * F::cast_from_int(value)
}

/// Half-open `(0, 1]` kernel: the same as [`standard_unit`] but with `+1` on the mantissa so the
/// zero sample maps to the smallest positive value and the all-ones sample maps to exactly `1`.
#[inline]
pub(crate) fn open_closed_unit<F, R>(rng: &mut R, scale: F, shift: u32) -> F
where
    F: FloatFromInt + FloatAsScalar + Mul<Output = F>,
    F::UInt: Shr<u32, Output = F::UInt> + Add<Output = F::UInt> + One,
    StandardUniform: Distribution<F::UInt>,
    R: Rng + ?Sized,
{
    let value: F::UInt = StandardUniform.sample(rng);
    let value = value >> shift;
    F::splat(scale) * F::cast_from_int(value + F::UInt::one())
}

/// Open `(0, 1)` kernel: build a value in `[1, 2)` via the exponent trick and subtract
/// `1 - eps/2`, leaving an open interval strictly inside the unit range.
#[inline]
pub(crate) fn open_unit<F, R>(rng: &mut R, shift: u32, one_minus_half_eps: F) -> F
where
    F: FloatFromInt + FloatAsScalar + Sub<Output = F>,
    F::UInt: Shr<u32, Output = F::UInt> + IntoFloat<F = F>,
    StandardUniform: Distribution<F::UInt>,
    R: Rng + ?Sized,
{
    let value: F::UInt = StandardUniform.sample(rng);
    let fraction = value >> shift;
    fraction.into_float_with_exponent(0) - F::splat(one_minus_half_eps)
}
