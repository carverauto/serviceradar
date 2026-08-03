/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AsPrimitive, Complex, FromPrimitive, NumCast, RealField, ToPrimitive};

// AsPrimitive
impl<T, U> AsPrimitive<U> for Complex<T>
where
    T: RealField + AsPrimitive<U> + 'static,
    U: 'static + Copy,
{
    #[inline]
    fn as_(self) -> U {
        self.re.as_()
    }
}

// NumCast
impl<T: RealField + NumCast> NumCast for Complex<T> {
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<Self> {
        T::from(n).map(Self::from_real)
    }
}

// FromPrimitive
impl<T: RealField + FromPrimitive> FromPrimitive for Complex<T> {
    fn from_isize(n: isize) -> Option<Self> {
        T::from_isize(n).map(Self::from_real)
    }
    fn from_i8(n: i8) -> Option<Self> {
        T::from_i8(n).map(Self::from_real)
    }
    fn from_i16(n: i16) -> Option<Self> {
        T::from_i16(n).map(Self::from_real)
    }
    fn from_i32(n: i32) -> Option<Self> {
        T::from_i32(n).map(Self::from_real)
    }
    fn from_i64(n: i64) -> Option<Self> {
        T::from_i64(n).map(Self::from_real)
    }
    fn from_i128(n: i128) -> Option<Self> {
        T::from_i128(n).map(Self::from_real)
    }
    fn from_usize(n: usize) -> Option<Self> {
        T::from_usize(n).map(Self::from_real)
    }
    fn from_u8(n: u8) -> Option<Self> {
        T::from_u8(n).map(Self::from_real)
    }
    fn from_u16(n: u16) -> Option<Self> {
        T::from_u16(n).map(Self::from_real)
    }
    fn from_u32(n: u32) -> Option<Self> {
        T::from_u32(n).map(Self::from_real)
    }
    fn from_u64(n: u64) -> Option<Self> {
        T::from_u64(n).map(Self::from_real)
    }
    fn from_u128(n: u128) -> Option<Self> {
        T::from_u128(n).map(Self::from_real)
    }
    fn from_f32(n: f32) -> Option<Self> {
        T::from_f32(n).map(Self::from_real)
    }
    fn from_f64(n: f64) -> Option<Self> {
        T::from_f64(n).map(Self::from_real)
    }
}

// ToPrimitive
impl<T: RealField + ToPrimitive> ToPrimitive for Complex<T> {
    fn to_isize(&self) -> Option<isize> {
        self.re.to_isize()
    }
    fn to_i8(&self) -> Option<i8> {
        self.re.to_i8()
    }
    fn to_i16(&self) -> Option<i16> {
        self.re.to_i16()
    }
    fn to_i32(&self) -> Option<i32> {
        self.re.to_i32()
    }
    fn to_i64(&self) -> Option<i64> {
        self.re.to_i64()
    }
    fn to_i128(&self) -> Option<i128> {
        self.re.to_i128()
    }
    fn to_usize(&self) -> Option<usize> {
        self.re.to_usize()
    }
    fn to_u8(&self) -> Option<u8> {
        self.re.to_u8()
    }
    fn to_u16(&self) -> Option<u16> {
        self.re.to_u16()
    }
    fn to_u32(&self) -> Option<u32> {
        self.re.to_u32()
    }
    fn to_u64(&self) -> Option<u64> {
        self.re.to_u64()
    }
    fn to_u128(&self) -> Option<u128> {
        self.re.to_u128()
    }
    fn to_f32(&self) -> Option<f32> {
        self.re.to_f32()
    }
    fn to_f64(&self) -> Option<f64> {
        self.re.to_f64()
    }
}
