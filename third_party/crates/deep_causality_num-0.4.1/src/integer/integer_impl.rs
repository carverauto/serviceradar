/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Integer;

macro_rules! impl_integer {
    ($($t:ty)*) => ($(
        impl Integer for $t {
            const MIN: Self = <$t>::MIN;
            const MAX: Self = <$t>::MAX;
            const BITS: u32 = <$t>::BITS;

            #[inline]
            fn count_ones(self) -> u32 {
                <$t>::count_ones(self)
            }

            #[inline]
            fn count_zeros(self) -> u32 {
                <$t>::count_zeros(self)
            }

            #[inline]
            fn leading_zeros(self) -> u32 {
                <$t>::leading_zeros(self)
            }

            #[inline]
            fn trailing_zeros(self) -> u32 {
                <$t>::trailing_zeros(self)
            }

            #[inline]
            fn swap_bytes(self) -> Self {
                <$t>::swap_bytes(self)
            }

            #[inline]
            fn from_be(x: Self) -> Self {
                <$t>::from_be(x)
            }

            #[inline]
            fn from_le(x: Self) -> Self {
                <$t>::from_le(x)
            }

            #[inline]
            fn to_be(self) -> Self {
                <$t>::to_be(self)
            }

            #[inline]
            fn to_le(self) -> Self {
                <$t>::to_le(self)
            }

            #[inline]
            fn checked_add(self, rhs: Self) -> Option<Self> {
                <$t>::checked_add(self, rhs)
            }

            #[inline]
            fn checked_sub(self, rhs: Self) -> Option<Self> {
                <$t>::checked_sub(self, rhs)
            }

            #[inline]
            fn checked_mul(self, rhs: Self) -> Option<Self> {
                <$t>::checked_mul(self, rhs)
            }

            #[inline]
            fn checked_div(self, rhs: Self) -> Option<Self> {
                <$t>::checked_div(self, rhs)
            }

            #[inline]
            fn checked_rem(self, rhs: Self) -> Option<Self> {
                <$t>::checked_rem(self, rhs)
            }

            #[inline]
            fn saturating_add(self, rhs: Self) -> Self {
                <$t>::saturating_add(self, rhs)
            }

            #[inline]
            fn saturating_sub(self, rhs: Self) -> Self {
                <$t>::saturating_sub(self, rhs)
            }

            #[inline]
            fn saturating_mul(self, rhs: Self) -> Self {
                <$t>::saturating_mul(self, rhs)
            }

            #[inline]
            fn wrapping_add(self, rhs: Self) -> Self {
                <$t>::wrapping_add(self, rhs)
            }

            #[inline]
            fn wrapping_sub(self, rhs: Self) -> Self {
                <$t>::wrapping_sub(self, rhs)
            }

            #[inline]
            fn wrapping_mul(self, rhs: Self) -> Self {
                <$t>::wrapping_mul(self, rhs)
            }

            #[inline]
            fn pow(self, exp: u32) -> Self {
                <$t>::pow(self, exp)
            }

            #[inline]
            fn div_euclid(self, rhs: Self) -> Self {
                <$t>::div_euclid(self, rhs)
            }

            #[inline]
            fn rem_euclid(self, rhs: Self) -> Self {
                <$t>::rem_euclid(self, rhs)
            }
        }
    )*)
}

impl_integer! { i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize }
