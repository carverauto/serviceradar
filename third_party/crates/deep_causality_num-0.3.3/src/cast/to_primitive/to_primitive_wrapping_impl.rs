/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::ToPrimitive;
use core::num::Wrapping;

impl<T: ToPrimitive> ToPrimitive for Wrapping<T> {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        (self.0).to_isize()
    }
    #[inline]
    fn to_i8(&self) -> Option<i8> {
        (self.0).to_i8()
    }
    #[inline]
    fn to_i16(&self) -> Option<i16> {
        (self.0).to_i16()
    }
    #[inline]
    fn to_i32(&self) -> Option<i32> {
        (self.0).to_i32()
    }
    #[inline]
    fn to_i64(&self) -> Option<i64> {
        (self.0).to_i64()
    }
    #[inline]
    fn to_i128(&self) -> Option<i128> {
        (self.0).to_i128()
    }
    #[inline]
    fn to_usize(&self) -> Option<usize> {
        (self.0).to_usize()
    }
    #[inline]
    fn to_u8(&self) -> Option<u8> {
        (self.0).to_u8()
    }
    #[inline]
    fn to_u16(&self) -> Option<u16> {
        (self.0).to_u16()
    }
    #[inline]
    fn to_u32(&self) -> Option<u32> {
        (self.0).to_u32()
    }
    #[inline]
    fn to_u64(&self) -> Option<u64> {
        (self.0).to_u64()
    }
    #[inline]
    fn to_u128(&self) -> Option<u128> {
        (self.0).to_u128()
    }
    #[inline]
    fn to_f32(&self) -> Option<f32> {
        (self.0).to_f32()
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        (self.0).to_f64()
    }
}
