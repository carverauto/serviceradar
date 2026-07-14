/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::IntAsScalar;

mod to_float_u32_impl;
mod to_float_u64_impl;

pub trait IntoFloat: IntAsScalar {
    type F;

    /// Helper method to combine the fraction and a constant exponent into a
    /// float.
    ///
    /// Only the least significant bits of `self` may be set, 23 for `f32` and
    /// 52 for `f64`.
    /// The resulting value will fall in a range that depends on the exponent.
    /// As an example the range with exponent 0 will be
    /// [2<sup>0</sup>..2<sup>1</sup>), which is [1..2).
    fn into_float_with_exponent(self, exponent: i32) -> Self::F;
}

pub trait FloatFromInt: Sized {
    type UInt;
    fn cast_from_int(i: Self::UInt) -> Self;
}

impl FloatFromInt for f32 {
    type UInt = u32;

    fn cast_from_int(i: Self::UInt) -> Self {
        i as f32
    }
}
impl FloatFromInt for f64 {
    type UInt = u64;

    fn cast_from_int(i: Self::UInt) -> Self {
        i as f64
    }
}
