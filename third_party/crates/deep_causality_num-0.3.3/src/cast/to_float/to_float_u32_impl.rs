/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{IntAsScalar, IntoFloat};

impl IntoFloat for u32 {
    type F = f32;
    #[inline(always)]
    fn into_float_with_exponent(self, exponent: i32) -> f32 {
        // The exponent is encoded using an offset-binary representation
        let exponent_bits: u32 = ((127 + exponent) as u32) << 23;
        f32::from_bits(self | u32::splat(exponent_bits))
    }
}
