/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::ToPrimitive;
use core::mem::size_of;
use core::{f32, f64};

impl ToPrimitive for usize {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as usize;
        if size_of::<usize>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as usize;
        if size_of::<usize>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as usize;
        if size_of::<usize>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as usize;
        if size_of::<usize>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as usize;
        if size_of::<usize>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as usize;
        if size_of::<usize>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX;
        if size_of::<usize>() <= size_of::<usize>() || *self <= max {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as usize;
        if size_of::<usize>() <= size_of::<u8>() || *self <= max {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as usize;
        if size_of::<usize>() <= size_of::<u16>() || *self <= max {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as usize;
        if size_of::<usize>() <= size_of::<u32>() || *self <= max {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as usize;
        if size_of::<usize>() <= size_of::<u64>() || *self <= max {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as usize;
        if size_of::<usize>() <= size_of::<u128>() || *self <= max {
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

impl ToPrimitive for u8 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as u8;
        if size_of::<u8>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as u8;
        if size_of::<u8>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as u8;
        if size_of::<u8>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as u8;
        if size_of::<u8>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as u8;
        if size_of::<u8>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as u8;
        if size_of::<u8>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as u8;
        if size_of::<u8>() <= size_of::<usize>() || *self <= max {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX;
        if size_of::<u8>() <= size_of::<u8>() || *self <= max {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as u8;
        if size_of::<u8>() <= size_of::<u16>() || *self <= max {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as u8;
        if size_of::<u8>() <= size_of::<u32>() || *self <= max {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as u8;
        if size_of::<u8>() <= size_of::<u64>() || *self <= max {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as u8;
        if size_of::<u8>() <= size_of::<u128>() || *self <= max {
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

impl ToPrimitive for u16 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as u16;
        if size_of::<u16>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as u16;
        if size_of::<u16>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as u16;
        if size_of::<u16>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as u16;
        if size_of::<u16>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as u16;
        if size_of::<u16>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as u16;
        if size_of::<u16>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as u16;
        if size_of::<u16>() <= size_of::<usize>() || *self <= max {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as u16;
        if size_of::<u16>() <= size_of::<u8>() || *self <= max {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX;
        if size_of::<u16>() <= size_of::<u16>() || *self <= max {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as u16;
        if size_of::<u16>() <= size_of::<u32>() || *self <= max {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as u16;
        if size_of::<u16>() <= size_of::<u64>() || *self <= max {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as u16;
        if size_of::<u16>() <= size_of::<u128>() || *self <= max {
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

impl ToPrimitive for u32 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as u32;
        if size_of::<u32>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as u32;
        if size_of::<u32>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as u32;
        if size_of::<u32>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as u32;
        if size_of::<u32>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as u32;
        if size_of::<u32>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as u32;
        if size_of::<u32>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as u32;
        if size_of::<u32>() <= size_of::<usize>() || *self <= max {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as u32;
        if size_of::<u32>() <= size_of::<u8>() || *self <= max {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as u32;
        if size_of::<u32>() <= size_of::<u16>() || *self <= max {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX;
        if size_of::<u32>() <= size_of::<u32>() || *self <= max {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as u32;
        if size_of::<u32>() <= size_of::<u64>() || *self <= max {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as u32;
        if size_of::<u32>() <= size_of::<u128>() || *self <= max {
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

impl ToPrimitive for u64 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as u64;
        if size_of::<u64>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as u64;
        if size_of::<u64>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as u64;
        if size_of::<u64>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as u64;
        if size_of::<u64>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as u64;
        if size_of::<u64>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as u64;
        if size_of::<u64>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as u64;
        if size_of::<u64>() <= size_of::<usize>() || *self <= max {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as u64;
        if size_of::<u64>() <= size_of::<u8>() || *self <= max {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as u64;
        if size_of::<u64>() <= size_of::<u16>() || *self <= max {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as u64;
        if size_of::<u64>() <= size_of::<u32>() || *self <= max {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX;
        if size_of::<u64>() <= size_of::<u64>() || *self <= max {
            Some(*self)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX as u64;
        if size_of::<u64>() <= size_of::<u128>() || *self <= max {
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

impl ToPrimitive for u128 {
    #[inline]
    fn to_isize(&self) -> Option<isize> {
        let max = isize::MAX as u128;
        if size_of::<u128>() < size_of::<isize>() || *self <= max {
            Some(*self as isize)
        } else {
            None
        }
    }

    #[inline]
    fn to_i8(&self) -> Option<i8> {
        let max = i8::MAX as u128;
        if size_of::<u128>() < size_of::<i8>() || *self <= max {
            Some(*self as i8)
        } else {
            None
        }
    }

    #[inline]
    fn to_i16(&self) -> Option<i16> {
        let max = i16::MAX as u128;
        if size_of::<u128>() < size_of::<i16>() || *self <= max {
            Some(*self as i16)
        } else {
            None
        }
    }

    #[inline]
    fn to_i32(&self) -> Option<i32> {
        let max = i32::MAX as u128;
        if size_of::<u128>() < size_of::<i32>() || *self <= max {
            Some(*self as i32)
        } else {
            None
        }
    }

    #[inline]
    fn to_i64(&self) -> Option<i64> {
        let max = i64::MAX as u128;
        if size_of::<u128>() < size_of::<i64>() || *self <= max {
            Some(*self as i64)
        } else {
            None
        }
    }

    #[inline]
    fn to_i128(&self) -> Option<i128> {
        let max = i128::MAX as u128;
        if size_of::<u128>() < size_of::<i128>() || *self <= max {
            Some(*self as i128)
        } else {
            None
        }
    }

    #[inline]
    fn to_usize(&self) -> Option<usize> {
        let max = usize::MAX as u128;
        if size_of::<u128>() <= size_of::<usize>() || *self <= max {
            Some(*self as usize)
        } else {
            None
        }
    }

    #[inline]
    fn to_u8(&self) -> Option<u8> {
        let max = u8::MAX as u128;
        if size_of::<u128>() <= size_of::<u8>() || *self <= max {
            Some(*self as u8)
        } else {
            None
        }
    }

    #[inline]
    fn to_u16(&self) -> Option<u16> {
        let max = u16::MAX as u128;
        if size_of::<u128>() <= size_of::<u16>() || *self <= max {
            Some(*self as u16)
        } else {
            None
        }
    }

    #[inline]
    fn to_u32(&self) -> Option<u32> {
        let max = u32::MAX as u128;
        if size_of::<u128>() <= size_of::<u32>() || *self <= max {
            Some(*self as u32)
        } else {
            None
        }
    }

    #[inline]
    fn to_u64(&self) -> Option<u64> {
        let max = u64::MAX as u128;
        if size_of::<u128>() <= size_of::<u64>() || *self <= max {
            Some(*self as u64)
        } else {
            None
        }
    }

    #[inline]
    fn to_u128(&self) -> Option<u128> {
        let max = u128::MAX;
        if size_of::<u128>() <= size_of::<u128>() || *self <= max {
            Some(*self)
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
