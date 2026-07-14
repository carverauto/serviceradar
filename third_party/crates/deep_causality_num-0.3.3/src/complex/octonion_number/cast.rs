/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AsPrimitive, FromPrimitive, NumCast, Octonion, RealField, ToPrimitive};

// AsPrimitive
impl<T, U> AsPrimitive<U> for Octonion<T>
where
    T: RealField + AsPrimitive<U> + 'static,
    U: 'static + Copy,
{
    /// Converts the octonion to a primitive type `U` by casting its scalar part.
    ///
    /// This method is part of the `AsPrimitive` trait, allowing the octonion's
    /// scalar component to be cast to various primitive numerical types.
    ///
    /// # Type Parameters
    /// * `U` - The target primitive type.
    ///
    /// # Returns
    /// The scalar part of the octonion, cast to type `U`.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, AsPrimitive};
    ///
    /// let o = Octonion::new(10.5f64, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
    /// let val_f32: f32 = o.as_();
    /// assert_eq!(val_f32, 10.5f32);
    ///
    /// let val_i32: i32 = o.as_();
    /// assert_eq!(val_i32, 10i32);
    /// ```
    #[inline]
    fn as_(self) -> U {
        self.s.as_()
    }
}

// NumCast
impl<T: RealField + NumCast> NumCast for Octonion<T> {
    /// Converts a number `n` into an `Octonion<T>`.
    ///
    /// This method is part of the `NumCast` trait. It attempts to convert any
    /// type `N` that implements `ToPrimitive` into an `Octonion<T>`.
    /// The conversion is applied only to the scalar part (`s`) of the octonion,
    /// with all imaginary parts set to zero.
    ///
    /// # Type Parameters
    /// * `N` - The numeric type to convert from.
    ///
    /// # Arguments
    /// * `n` - The value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion<T>)` if the conversion is
    /// successful and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, NumCast};
    ///
    /// let o: Option<Octonion<f64>> = <Octonion<_> as NumCast>::from(10);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 10.0);
    ///
    /// let o_float: Option<Octonion<f32>> = <Octonion<_> as NumCast>::from(3.14f64);
    /// assert!(o_float.is_some());
    /// assert_eq!(o_float.unwrap().s, 3.14f32);
    /// ```
    #[inline]
    fn from<N: ToPrimitive>(n: N) -> Option<Self> {
        T::from(n).map(Self::from_real)
    }
}

// FromPrimitive
/// Implements the `FromPrimitive` trait for `Octonion`.
///
/// This allows conversion from various primitive integer and floating-point types
/// into an `Octonion`. The converted value populates the scalar part (`s`)
/// of the octonion, with all imaginary parts set to zero.
///
/// Each `from_*` method attempts to convert the given primitive value into
/// the underlying real field type `T` and then constructs an `Octonion` from it.
impl<T: RealField + FromPrimitive> FromPrimitive for Octonion<T> {
    /// Converts an `isize` value into an `Octonion`.
    ///
    /// The `isize` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `isize` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_isize(10);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 10.0);
    /// ```
    fn from_isize(n: isize) -> Option<Self> {
        T::from_isize(n).map(Self::from_real)
    }
    /// Converts an `i8` value into an `Octonion`.
    ///
    /// The `i8` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `i8` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_i8(5);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 5.0);
    /// ```
    fn from_i8(n: i8) -> Option<Self> {
        T::from_i8(n).map(Self::from_real)
    }
    /// Converts an `i16` value into an `Octonion`.
    ///
    /// The `i16` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `i16` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_i16(100);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 100.0);
    /// ```
    fn from_i16(n: i16) -> Option<Self> {
        T::from_i16(n).map(Self::from_real)
    }
    /// Converts an `i32` value into an `Octonion`.
    ///
    /// The `i32` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `i32` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_i32(1000);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 1000.0);
    /// ```
    fn from_i32(n: i32) -> Option<Self> {
        T::from_i32(n).map(Self::from_real)
    }
    /// Converts an `i64` value into an `Octonion`.
    ///
    /// The `i64` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `i64` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_i64(100_000);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 100_000.0);
    /// ```
    fn from_i64(n: i64) -> Option<Self> {
        T::from_i64(n).map(Self::from_real)
    }
    /// Converts an `i128` value into an `Octonion`.
    ///
    /// The `i128` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `i128` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_i128(1_000_000_000_000);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 1_000_000_000_000.0);
    /// ```
    fn from_i128(n: i128) -> Option<Self> {
        T::from_i128(n).map(Self::from_real)
    }
    /// Converts a `usize` value into an `Octonion`.
    ///
    /// The `usize` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `usize` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_usize(123);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 123.0);
    /// ```
    fn from_usize(n: usize) -> Option<Self> {
        T::from_usize(n).map(Self::from_real)
    }
    /// Converts a `u8` value into an `Octonion`.
    ///
    /// The `u8` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `u8` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_u8(255);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 255.0);
    /// ```
    fn from_u8(n: u8) -> Option<Self> {
        T::from_u8(n).map(Self::from_real)
    }
    /// Converts a `u16` value into an `Octonion`.
    ///
    /// The `u16` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `u16` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_u16(65535);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 65535.0);
    /// ```
    fn from_u16(n: u16) -> Option<Self> {
        T::from_u16(n).map(Self::from_real)
    }
    /// Converts a `u32` value into an `Octonion`.
    ///
    /// The `u32` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `u32` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_u32(4_000_000_000);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 4_000_000_000.0);
    /// ```
    fn from_u32(n: u32) -> Option<Self> {
        T::from_u32(n).map(Self::from_real)
    }
    /// Converts a `u64` value into an `Octonion`.
    ///
    /// The `u64` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `u64` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_u64(u64::MAX);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, u64::MAX as f64);
    /// ```
    fn from_u64(n: u64) -> Option<Self> {
        T::from_u64(n).map(Self::from_real)
    }
    /// Converts a `u128` value into an `Octonion`.
    ///
    /// The `u128` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `u128` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_u128(u128::MAX);
    /// assert!(o.is_some());
    /// // Note: f64 can't represent all u128 values precisely.
    /// assert_eq!(o.unwrap().s, u128::MAX as f64);
    /// ```
    fn from_u128(n: u128) -> Option<Self> {
        T::from_u128(n).map(Self::from_real)
    }
    /// Converts an `f32` value into an `Octonion`.
    ///
    /// The `f32` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `f32` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f64>> = Octonion::from_f32(3.14f32);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 3.14f32 as f64);
    /// ```
    fn from_f32(n: f32) -> Option<Self> {
        T::from_f32(n).map(Self::from_real)
    }
    /// Converts an `f64` value into an `Octonion`.
    ///
    /// The `f64` value is used for the scalar part of the octonion, and all
    /// imaginary parts are set to zero.
    ///
    /// # Arguments
    /// * `n` - The `f64` value to convert.
    ///
    /// # Returns
    /// An `Option<Self>` which is `Some(Octonion)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, FromPrimitive};
    ///
    /// let o: Option<Octonion<f32>> = Octonion::from_f64(2.718f64);
    /// assert!(o.is_some());
    /// assert_eq!(o.unwrap().s, 2.718f32);
    /// ```
    fn from_f64(n: f64) -> Option<Self> {
        T::from_f64(n).map(Self::from_real)
    }
}

// ToPrimitive
/// Implements the `ToPrimitive` trait for `Octonion`.
///
/// This allows conversion from an `Octonion` into various primitive integer
/// and floating-point types. The conversion is performed only on the scalar part (`s`)
/// of the octonion.
///
/// Each `to_*` method attempts to convert the octonion's scalar part into
/// the target primitive type.
impl<F: RealField + ToPrimitive> ToPrimitive for Octonion<F> {
    /// Converts the scalar part of the `Octonion` to an `isize`.
    ///
    /// # Returns
    /// An `Option<isize>` which is `Some(isize)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(10.5f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<isize> = o.to_isize();
    /// assert_eq!(val, Some(10));
    /// ```
    fn to_isize(&self) -> Option<isize> {
        self.s.to_isize()
    }
    /// Converts the scalar part of the `Octonion` to an `i8`.
    ///
    /// # Returns
    /// An `Option<i8>` which is `Some(i8)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(5.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<i8> = o.to_i8();
    /// assert_eq!(val, Some(5));
    /// ```
    fn to_i8(&self) -> Option<i8> {
        self.s.to_i8()
    }
    /// Converts the scalar part of the `Octonion` to an `i16`.
    ///
    /// # Returns
    /// An `Option<i16>` which is `Some(i16)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(100.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<i16> = o.to_i16();
    /// assert_eq!(val, Some(100));
    /// ```
    fn to_i16(&self) -> Option<i16> {
        self.s.to_i16()
    }
    /// Converts the scalar part of the `Octonion` to an `i32`.
    ///
    /// # Returns
    /// An `Option<i32>` which is `Some(i32)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(1000.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<i32> = o.to_i32();
    /// assert_eq!(val, Some(1000));
    /// ```
    fn to_i32(&self) -> Option<i32> {
        self.s.to_i32()
    }
    /// Converts the scalar part of the `Octonion` to an `i64`.
    ///
    /// # Returns
    /// An `Option<i64>` which is `Some(i64)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(100_000.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<i64> = o.to_i64();
    /// assert_eq!(val, Some(100_000));
    /// ```
    fn to_i64(&self) -> Option<i64> {
        self.s.to_i64()
    }
    /// Converts the scalar part of the `Octonion` to an `i128`.
    ///
    /// # Returns
    /// An `Option<i128>` which is `Some(i128)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(1_000_000_000_000_000.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<i128> = o.to_i128();
    /// assert_eq!(val, Some(1_000_000_000_000_000));
    /// ```
    fn to_i128(&self) -> Option<i128> {
        self.s.to_i128()
    }
    /// Converts the scalar part of the `Octonion` to a `usize`.
    ///
    /// # Returns
    /// An `Option<usize>` which is `Some(usize)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(123.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<usize> = o.to_usize();
    /// assert_eq!(val, Some(123));
    /// ```
    fn to_usize(&self) -> Option<usize> {
        self.s.to_usize()
    }
    /// Converts the scalar part of the `Octonion` to a `u8`.
    ///
    /// # Returns
    /// An `Option<u8>` which is `Some(u8)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(255.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<u8> = o.to_u8();
    /// assert_eq!(val, Some(255));
    /// ```
    fn to_u8(&self) -> Option<u8> {
        self.s.to_u8()
    }
    /// Converts the scalar part of the `Octonion` to a `u16`.
    ///
    /// # Returns
    /// An `Option<u16>` which is `Some(u16)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(65535.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<u16> = o.to_u16();
    /// assert_eq!(val, Some(65535));
    /// ```
    fn to_u16(&self) -> Option<u16> {
        self.s.to_u16()
    }
    /// Converts the scalar part of the `Octonion` to a `u32`.
    ///
    /// # Returns
    /// An `Option<u32>` which is `Some(u32)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(4_000_000_000.0f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<u32> = o.to_u32();
    /// assert_eq!(val, Some(4_000_000_000));
    /// ```
    fn to_u32(&self) -> Option<u32> {
        self.s.to_u32()
    }
    /// Converts the scalar part of the `Octonion` to a `u64`.
    ///
    /// # Returns
    /// An `Option<u64>` which is `Some(u64)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(u64::MAX as f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<u64> = o.to_u64();
    /// assert_eq!(val, Some(u64::MAX));
    /// ```
    fn to_u64(&self) -> Option<u64> {
        self.s.to_u64()
    }
    /// Converts the scalar part of the `Octonion` to a `u128`.
    ///
    /// # Returns
    /// An `Option<u128>` which is `Some(u128)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(u128::MAX as f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<u128> = o.to_u128();
    /// // Note: f64 can't represent all u128 values precisely.
    /// assert_eq!(val, Some(u128::MAX));
    /// ```
    fn to_u128(&self) -> Option<u128> {
        self.s.to_u128()
    }
    /// Converts the scalar part of the `Octonion` to an `f32`.
    ///
    /// # Returns
    /// An `Option<f32>` which is `Some(f32)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(3.1415926535f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<f32> = o.to_f32();
    /// assert_eq!(val, Some(3.1415927f32));
    /// ```
    fn to_f32(&self) -> Option<f32> {
        self.s.to_f32()
    }
    /// Converts the scalar part of the `Octonion` to an `f64`.
    ///
    /// # Returns
    /// An `Option<f64>` which is `Some(f64)` if the conversion is successful,
    /// and `None` otherwise.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::{Octonion, ToPrimitive};
    ///
    /// let o = Octonion::new(2.718281828f64, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
    /// let val: Option<f64> = o.to_f64();
    /// assert_eq!(val, Some(2.718281828f64));
    /// ```
    fn to_f64(&self) -> Option<f64> {
        self.s.to_f64()
    }
}
