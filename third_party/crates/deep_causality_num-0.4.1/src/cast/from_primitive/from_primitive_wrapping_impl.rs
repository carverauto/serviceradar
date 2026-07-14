/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::FromPrimitive;
use core::num::Wrapping;

impl<T: FromPrimitive> FromPrimitive for Wrapping<T> {
    #[inline]
    fn from_isize(n: isize) -> Option<Self> {
        T::from_isize(n).map(Wrapping)
    }
    #[inline]
    fn from_i8(n: i8) -> Option<Self> {
        T::from_i8(n).map(Wrapping)
    }
    #[inline]
    fn from_i16(n: i16) -> Option<Self> {
        T::from_i16(n).map(Wrapping)
    }
    #[inline]
    fn from_i32(n: i32) -> Option<Self> {
        T::from_i32(n).map(Wrapping)
    }
    #[inline]
    fn from_i64(n: i64) -> Option<Self> {
        T::from_i64(n).map(Wrapping)
    }
    #[inline]
    fn from_i128(n: i128) -> Option<Self> {
        T::from_i128(n).map(Wrapping)
    }
    #[inline]
    fn from_usize(n: usize) -> Option<Self> {
        T::from_usize(n).map(Wrapping)
    }
    #[inline]
    fn from_u8(n: u8) -> Option<Self> {
        T::from_u8(n).map(Wrapping)
    }
    #[inline]
    fn from_u16(n: u16) -> Option<Self> {
        T::from_u16(n).map(Wrapping)
    }
    #[inline]
    fn from_u32(n: u32) -> Option<Self> {
        T::from_u32(n).map(Wrapping)
    }
    #[inline]
    fn from_u64(n: u64) -> Option<Self> {
        T::from_u64(n).map(Wrapping)
    }
    #[inline]
    fn from_u128(n: u128) -> Option<Self> {
        T::from_u128(n).map(Wrapping)
    }
    #[inline]
    fn from_f32(n: f32) -> Option<Self> {
        T::from_f32(n).map(Wrapping)
    }
    #[inline]
    fn from_f64(n: f64) -> Option<Self> {
        T::from_f64(n).map(Wrapping)
    }
}
