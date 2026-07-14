/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Quaternion;
use crate::{AsPrimitive, Field, FromPrimitive, NumCast, RealField, ToPrimitive};

// AsPrimitive
impl<F: Field, T> AsPrimitive<T> for Quaternion<F>
where
    F: AsPrimitive<T>,
    T: 'static + Copy + NumCast,
{
    #[inline]
    fn as_(self) -> T {
        self.w.as_() // Only the scalar part is converted
    }
}

// NumCast
impl<F: RealField + NumCast> NumCast for Quaternion<F> {
    #[inline]
    fn from<T: ToPrimitive>(n: T) -> Option<Self> {
        F::from(n).map(|f| Quaternion::new(f, F::zero(), F::zero(), F::zero()))
    }
}

// FromPrimitive
impl<T: RealField + FromPrimitive> FromPrimitive for Quaternion<T> {
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
impl<F: RealField + ToPrimitive> ToPrimitive for Quaternion<F> {
    /// Converts the scalar part (`w`) of the quaternion to an `isize`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_isize(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_isize(), None);
    /// ```
    fn to_isize(&self) -> Option<isize> {
        self.w.to_isize()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `i8`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_i8(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_i8(), None);
    /// ```
    fn to_i8(&self) -> Option<i8> {
        self.w.to_i8()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `i16`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_i16(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_i16(), None);
    /// ```
    fn to_i16(&self) -> Option<i16> {
        self.w.to_i16()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `i32`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_i32(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_i32(), None);
    /// ```
    fn to_i32(&self) -> Option<i32> {
        self.w.to_i32()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `i64`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_i64(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_i64(), None);
    /// ```
    fn to_i64(&self) -> Option<i64> {
        self.w.to_i64()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `i128`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_i128(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_i128(), None);
    /// ```
    fn to_i128(&self) -> Option<i128> {
        self.w.to_i128()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `usize`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_usize(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_usize(), None);
    /// ```
    fn to_usize(&self) -> Option<usize> {
        self.w.to_usize()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `u8`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_u8(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_u8(), None);
    /// ```
    fn to_u8(&self) -> Option<u8> {
        self.w.to_u8()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `u16`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_u16(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_u16(), None);
    /// ```
    fn to_u16(&self) -> Option<u16> {
        self.w.to_u16()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `u32`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_u32(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_u32(), None);
    /// ```
    fn to_u32(&self) -> Option<u32> {
        self.w.to_u32()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `u64`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_u64(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_u64(), None);
    /// ```
    fn to_u64(&self) -> Option<u64> {
        self.w.to_u64()
    }

    /// Converts the scalar part (`w`) of the quaternion to a `u128`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_u128(), Some(123));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert_eq!(q_nan.to_u128(), None);
    /// ```
    fn to_u128(&self) -> Option<u128> {
        self.w.to_u128()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `f32`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_f32(), Some(123.45f32));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert!(q_nan.to_f32().unwrap().is_nan());
    /// ```
    fn to_f32(&self) -> Option<f32> {
        self.w.to_f32()
    }

    /// Converts the scalar part (`w`) of the quaternion to an `f64`.
    /// Returns `None` if the conversion is not possible (e.g., `NaN`, `Infinity`, or out of range).
    ///
    /// # Examples
    ///
    /// ```
    /// use deep_causality_num::Quaternion;
    /// use deep_causality_num::ToPrimitive;
    ///
    /// let q = Quaternion::new(123.45, 0.0, 0.0, 0.0);
    /// assert_eq!(q.to_f64(), Some(123.45f64));
    ///
    /// let q_nan = Quaternion::new(f64::NAN, 0.0, 0.0, 0.0);
    /// assert!(q_nan.to_f64().unwrap().is_nan());
    /// ```
    fn to_f64(&self) -> Option<f64> {
        self.w.to_f64()
    }
}
