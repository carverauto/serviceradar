/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::AsPrimitive;

// bool
impl AsPrimitive<u8> for bool {
    #[inline]
    fn as_(self) -> u8 {
        self as u8
    }
}
impl AsPrimitive<u16> for bool {
    #[inline]
    fn as_(self) -> u16 {
        self as u16
    }
}
impl AsPrimitive<u32> for bool {
    #[inline]
    fn as_(self) -> u32 {
        self as u32
    }
}
impl AsPrimitive<u64> for bool {
    #[inline]
    fn as_(self) -> u64 {
        self as u64
    }
}
impl AsPrimitive<u128> for bool {
    #[inline]
    fn as_(self) -> u128 {
        self as u128
    }
}
impl AsPrimitive<usize> for bool {
    #[inline]
    fn as_(self) -> usize {
        self as usize
    }
}
impl AsPrimitive<i8> for bool {
    #[inline]
    fn as_(self) -> i8 {
        self as i8
    }
}
impl AsPrimitive<i16> for bool {
    #[inline]
    fn as_(self) -> i16 {
        self as i16
    }
}
impl AsPrimitive<i32> for bool {
    #[inline]
    fn as_(self) -> i32 {
        self as i32
    }
}
impl AsPrimitive<i64> for bool {
    #[inline]
    fn as_(self) -> i64 {
        self as i64
    }
}
impl AsPrimitive<i128> for bool {
    #[inline]
    fn as_(self) -> i128 {
        self as i128
    }
}
impl AsPrimitive<isize> for bool {
    #[inline]
    fn as_(self) -> isize {
        self as isize
    }
}
