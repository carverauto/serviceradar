/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Numeric trait implementations for `DoubleFloat`.

use crate::Float106;
use crate::{FromPrimitive, NumCast, ToPrimitive};

// =============================================================================
// ToPrimitive
// =============================================================================

impl ToPrimitive for Float106 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        self.hi.to_isize()
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        self.hi.to_i8()
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        self.hi.to_i16()
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        self.hi.to_i32()
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        self.hi.to_i64()
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        self.hi.to_i128()
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        self.hi.to_usize()
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        self.hi.to_u8()
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        self.hi.to_u16()
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        self.hi.to_u32()
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        self.hi.to_u64()
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        self.hi.to_u128()
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(self.hi as f32)
    }

    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(self.hi)
    }
}

// =============================================================================
// FromPrimitive
// =============================================================================

impl FromPrimitive for Float106 {
    #[inline]
    fn from_i64(n: i64) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_u64(n: u64) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_isize(n: isize) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_i8(n: i8) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_i16(n: i16) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_i32(n: i32) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_i128(n: i128) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_usize(n: usize) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_u8(n: u8) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_u16(n: u16) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_u32(n: u32) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_u128(n: u128) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_f32(n: f32) -> Option<Self> {
        Some(Self::from_f64(n as f64))
    }

    #[inline]
    fn from_f64(n: f64) -> Option<Self> {
        Some(Self::from_f64(n))
    }
}

// =============================================================================
// NumCast
// =============================================================================

impl NumCast for Float106 {
    #[inline]
    fn from<T: ToPrimitive>(n: T) -> Option<Self> {
        n.to_f64().map(Self::from_f64)
    }
}

// =============================================================================
// Sum and Product
// =============================================================================

use core::iter::{Product, Sum};

impl Sum for Float106 {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::from_f64(0.0), |acc, x| acc + x)
    }
}

impl<'a> Sum<&'a Float106> for Float106 {
    fn sum<I: Iterator<Item = &'a Self>>(iter: I) -> Self {
        iter.fold(Self::from_f64(0.0), |acc, x| acc + *x)
    }
}

impl Product for Float106 {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::from_f64(1.0), |acc, x| acc * x)
    }
}

impl<'a> Product<&'a Float106> for Float106 {
    fn product<I: Iterator<Item = &'a Self>>(iter: I) -> Self {
        iter.fold(Self::from_f64(1.0), |acc, x| acc * *x)
    }
}
