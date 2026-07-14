/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

pub trait IntAsScalar: Sized {
    #[inline(always)]
    fn splat(scalar: Self) -> Self {
        scalar
    }
}

impl IntAsScalar for u8 {}
impl IntAsScalar for u16 {}
impl IntAsScalar for u32 {}
impl IntAsScalar for u64 {}
impl IntAsScalar for u128 {}
