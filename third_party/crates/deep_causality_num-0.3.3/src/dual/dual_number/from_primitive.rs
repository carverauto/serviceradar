/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Dual, FromPrimitive, Real};

/// A primitive converts into a **constant** dual (`x + 0·ε`).
///
/// A constant has zero derivative, so a value lifted this way never contaminates the `ε`
/// channel. The conversion forwards through every nesting level, so `Dual<Dual<…>>` is
/// `FromPrimitive` too. This is the precision-safe, nesting-safe constant lift that lets
/// forward-mode automatic differentiation carry literal constants at any base precision
/// (`f32` / `f64` / `Float106`) — where `From<f64>` would silently exclude `f32`, which does
/// not implement it.
impl<T: Real + FromPrimitive> FromPrimitive for Dual<T> {
    #[inline]
    fn from_isize(n: isize) -> Option<Self> {
        T::from_isize(n).map(Dual::constant)
    }
    #[inline]
    fn from_i8(n: i8) -> Option<Self> {
        T::from_i8(n).map(Dual::constant)
    }
    #[inline]
    fn from_i16(n: i16) -> Option<Self> {
        T::from_i16(n).map(Dual::constant)
    }
    #[inline]
    fn from_i32(n: i32) -> Option<Self> {
        T::from_i32(n).map(Dual::constant)
    }
    #[inline]
    fn from_i64(n: i64) -> Option<Self> {
        T::from_i64(n).map(Dual::constant)
    }
    #[inline]
    fn from_i128(n: i128) -> Option<Self> {
        T::from_i128(n).map(Dual::constant)
    }
    #[inline]
    fn from_usize(n: usize) -> Option<Self> {
        T::from_usize(n).map(Dual::constant)
    }
    #[inline]
    fn from_u8(n: u8) -> Option<Self> {
        T::from_u8(n).map(Dual::constant)
    }
    #[inline]
    fn from_u16(n: u16) -> Option<Self> {
        T::from_u16(n).map(Dual::constant)
    }
    #[inline]
    fn from_u32(n: u32) -> Option<Self> {
        T::from_u32(n).map(Dual::constant)
    }
    #[inline]
    fn from_u64(n: u64) -> Option<Self> {
        T::from_u64(n).map(Dual::constant)
    }
    #[inline]
    fn from_u128(n: u128) -> Option<Self> {
        T::from_u128(n).map(Dual::constant)
    }
    #[inline]
    fn from_f32(n: f32) -> Option<Self> {
        T::from_f32(n).map(Dual::constant)
    }
    #[inline]
    fn from_f64(n: f64) -> Option<Self> {
        T::from_f64(n).map(Dual::constant)
    }
}
