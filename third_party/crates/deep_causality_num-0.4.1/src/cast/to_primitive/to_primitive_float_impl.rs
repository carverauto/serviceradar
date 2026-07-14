/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ToPrimitive;
use core::{f32, f64};

impl ToPrimitive for f32 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < isize::MIN as f64 || val_f64 > isize::MAX as f64 {
            return None;
        }
        Some(val_f64 as isize)
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < i8::MIN as f64 || val_f64 > i8::MAX as f64 {
            return None;
        }
        Some(val_f64 as i8)
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < i16::MIN as f64 || val_f64 > i16::MAX as f64 {
            return None;
        }
        Some(val_f64 as i16)
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < i32::MIN as f64 || val_f64 > i32::MAX as f64 {
            return None;
        }
        Some(val_f64 as i32)
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < i64::MIN as f64 || val_f64 > i64::MAX as f64 {
            return None;
        }
        Some(val_f64 as i64)
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 < i128::MIN as f64 || val_f64 > i128::MAX as f64 {
            return None;
        }
        Some(val_f64 as i128)
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > usize::MAX as f64 {
            return None;
        }
        Some(val_f64 as usize)
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > u8::MAX as f64 {
            return None;
        }
        Some(val_f64 as u8)
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > u16::MAX as f64 {
            return None;
        }
        Some(val_f64 as u16)
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > u32::MAX as f64 {
            return None;
        }
        Some(val_f64 as u32)
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > u64::MAX as f64 {
            return None;
        }
        Some(val_f64 as u64)
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        let val_f64 = *self as f64;
        if val_f64 > u128::MAX as f64 {
            return None;
        }
        Some(val_f64 as u128)
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self)
    }

    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for f64 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < isize::MIN as f64 || *self > isize::MAX as f64 {
            return None;
        }
        Some(*self as isize)
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < i8::MIN as f64 || *self > i8::MAX as f64 {
            return None;
        }
        Some(*self as i8)
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < i16::MIN as f64 || *self > i16::MAX as f64 {
            return None;
        }
        Some(*self as i16)
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < i32::MIN as f64 || *self > i32::MAX as f64 {
            return None;
        }
        Some(*self as i32)
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < i64::MIN as f64 || *self > i64::MAX as f64 {
            return None;
        }
        Some(*self as i64)
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        if self.is_nan() || self.is_infinite() {
            return None;
        }
        if *self < i128::MIN as f64 || *self > i128::MAX as f64 {
            return None;
        }
        Some(*self as i128)
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > usize::MAX as f64 {
            return None;
        }
        Some(*self as usize)
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > u8::MAX as f64 {
            return None;
        }
        Some(*self as u8)
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > u16::MAX as f64 {
            return None;
        }
        Some(*self as u16)
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > u32::MAX as f64 {
            return None;
        }
        Some(*self as u32)
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > u64::MAX as f64 {
            return None;
        }
        Some(*self as u64)
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        if self.is_nan() || self.is_infinite() || self.is_sign_negative() {
            return None;
        }
        if *self > u128::MAX as f64 {
            return None;
        }
        Some(*self as u128)
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }

    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self)
    }
}
