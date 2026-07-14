/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub trait FloatAsScalar: Sized {
    #[inline(always)]
    fn splat(scalar: Self) -> Self {
        scalar
    }
}

impl FloatAsScalar for f32 {}
impl FloatAsScalar for f64 {}
