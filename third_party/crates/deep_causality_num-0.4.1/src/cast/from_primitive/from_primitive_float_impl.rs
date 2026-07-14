/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{FromPrimitive, ToPrimitive};

impl FromPrimitive for f32 {
    #[inline]
    fn from_isize(n: isize) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_i8(n: i8) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_i16(n: i16) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_i32(n: i32) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_i64(n: i64) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_i128(n: i128) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_usize(n: usize) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_u8(n: u8) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_u16(n: u16) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_u32(n: u32) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_u64(n: u64) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_u128(n: u128) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_f32(n: f32) -> Option<f32> {
        n.to_f32()
    }
    #[inline]
    fn from_f64(n: f64) -> Option<f32> {
        n.to_f32()
    }
}

impl FromPrimitive for f64 {
    #[inline]
    fn from_isize(n: isize) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_i8(n: i8) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_i16(n: i16) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_i32(n: i32) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_i64(n: i64) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_i128(n: i128) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_usize(n: usize) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_u8(n: u8) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_u16(n: u16) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_u32(n: u32) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_u64(n: u64) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_u128(n: u128) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_f32(n: f32) -> Option<f64> {
        n.to_f64()
    }
    #[inline]
    fn from_f64(n: f64) -> Option<f64> {
        n.to_f64()
    }
}
