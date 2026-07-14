/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{NumCast, ToPrimitive};

impl NumCast for u8 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<u8> {
        n.to_u8()
    }
}

impl NumCast for u16 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<u16> {
        n.to_u16()
    }
}

impl NumCast for u32 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<u32> {
        n.to_u32()
    }
}

impl NumCast for u64 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<u64> {
        n.to_u64()
    }
}

impl NumCast for u128 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<u128> {
        n.to_u128()
    }
}

impl NumCast for usize {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<usize> {
        n.to_usize()
    }
}

impl NumCast for i8 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<i8> {
        n.to_i8()
    }
}

impl NumCast for i16 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<i16> {
        n.to_i16()
    }
}

impl NumCast for i32 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<i32> {
        n.to_i32()
    }
}

impl NumCast for i64 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<i64> {
        n.to_i64()
    }
}

impl NumCast for i128 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<i128> {
        n.to_i128()
    }
}

impl NumCast for isize {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<isize> {
        n.to_isize()
    }
}

impl NumCast for f32 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<f32> {
        n.to_f32()
    }
}

impl NumCast for f64 {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<f64> {
        n.to_f64()
    }
}
