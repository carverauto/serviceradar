/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{IntAsScalar, IntoFloat};

impl IntoFloat for u64 {
    type F = f64;
    #[inline(always)]
    fn into_float_with_exponent(self, exponent: i32) -> f64 {
        // The exponent is encoded using an offset-binary representation
        let exponent_bits: u64 = ((1023 + exponent) as u64) << 52;
        f64::from_bits(self | u64::splat(exponent_bits))
    }
}
