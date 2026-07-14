/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ToPrimitive;
use core::mem::size_of;
use core::{f32, f64};

impl ToPrimitive for isize {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN;
        let max = isize::MAX;
        if size_of::<isize>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN as isize;
        let max = i8::MAX as isize;
        if size_of::<isize>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN as isize;
        let max = i16::MAX as isize;
        if size_of::<isize>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN as isize;
        let max = i32::MAX as isize;
        if size_of::<isize>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN as isize;
        let max = i64::MAX as isize;
        if size_of::<isize>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN as isize;
        let max = i128::MAX as isize;
        if size_of::<isize>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as isize;
        if 0 <= *self && (size_of::<isize>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for i8 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN as i8;
        let max = isize::MAX as i8;
        if size_of::<i8>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN;
        let max = i8::MAX;
        if size_of::<i8>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN as i8;
        let max = i16::MAX as i8;
        if size_of::<i8>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN as i8;
        let max = i32::MAX as i8;
        if size_of::<i8>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN as i8;
        let max = i64::MAX as i8;
        if size_of::<i8>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN as i8;
        let max = i128::MAX as i8;
        if size_of::<i8>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as i8;
        if 0 <= *self && (size_of::<i8>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for i16 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN as i16;
        let max = isize::MAX as i16;
        if size_of::<i16>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN as i16;
        let max = i8::MAX as i16;
        if size_of::<i16>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN;
        let max = i16::MAX;
        if size_of::<i16>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN as i16;
        let max = i32::MAX as i16;
        if size_of::<i16>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN as i16;
        let max = i64::MAX as i16;
        if size_of::<i16>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN as i16;
        let max = i128::MAX as i16;
        if size_of::<i16>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as i16;
        if 0 <= *self && (size_of::<i16>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for i32 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN as i32;
        let max = isize::MAX as i32;
        if size_of::<i32>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN as i32;
        let max = i8::MAX as i32;
        if size_of::<i32>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN as i32;
        let max = i16::MAX as i32;
        if size_of::<i32>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN;
        let max = i32::MAX;
        if size_of::<i32>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN as i32;
        let max = i64::MAX as i32;
        if size_of::<i32>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN as i32;
        let max = i128::MAX as i32;
        if size_of::<i32>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as i32;
        if 0 <= *self && (size_of::<i32>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for i64 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN as i64;
        let max = isize::MAX as i64;
        if size_of::<i64>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN as i64;
        let max = i8::MAX as i64;
        if size_of::<i64>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN as i64;
        let max = i16::MAX as i64;
        if size_of::<i64>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN as i64;
        let max = i32::MAX as i64;
        if size_of::<i64>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN;
        let max = i64::MAX;
        if size_of::<i64>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN as i64;
        let max = i128::MAX as i64;
        if size_of::<i64>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as i64;
        if 0 <= *self && (size_of::<i64>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}

impl ToPrimitive for i128 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let min = isize::MIN as i128;
        let max = isize::MAX as i128;
        if size_of::<i128>() <= size_of::<isize>() || (min <= *self && *self <= max) {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let min = i8::MIN as i128;
        let max = i8::MAX as i128;
        if size_of::<i128>() <= size_of::<i8>() || (min <= *self && *self <= max) {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let min = i16::MIN as i128;
        let max = i16::MAX as i128;
        if size_of::<i128>() <= size_of::<i16>() || (min <= *self && *self <= max) {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let min = i32::MIN as i128;
        let max = i32::MAX as i128;
        if size_of::<i128>() <= size_of::<i32>() || (min <= *self && *self <= max) {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let min = i64::MIN as i128;
        let max = i64::MAX as i128;
        if size_of::<i128>() <= size_of::<i64>() || (min <= *self && *self <= max) {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let min = i128::MIN;
        let max = i128::MAX;
        if size_of::<i128>() <= size_of::<i128>() || (min <= *self && *self <= max) {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<usize>() || *self <= max) {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<u8>() || *self <= max) {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<u16>() || *self <= max) {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<u32>() || *self <= max) {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<u64>() || *self <= max) {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as i128;
        if 0 <= *self && (size_of::<i128>() <= size_of::<u128>() || *self <= max) {
            Some(*self as u128)
        } else {
            None
        }
    }

    #[inline]
    fn to_f32(&self) -> Option<f32> {
        Some(*self as f32)
    }
    #[inline]
    fn to_f64(&self) -> Option<f64> {
        Some(*self as f64)
    }
}
