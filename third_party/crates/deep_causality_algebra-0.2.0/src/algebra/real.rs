/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{CommutativeRing, Float};
use core::cmp::PartialOrd;
use core::ops::{AddAssign, MulAssign, Neg, SubAssign};

/// An analytic real scalar: commutative-ring arithmetic plus the elementary
/// functions, constants, ordering, rounding, and exceptional-value predicates of
/// the real numbers — **without** field invertibility.
///
/// `Real` captures the *analytic* axis of a real number (sqrt, exp, ln, sin, …)
/// decoupled from the *field* axis (a total multiplicative inverse / division).
/// That separation is deliberate: a type can be analytic without being a field.
/// The motivating case is the dual number `a + b·ε` (`ε² = 0`) used for forward-mode
/// automatic differentiation — it has every elementary function (by the chain rule)
/// but is **not** a field, because `ε` is a zero divisor. Such a type implements
/// `Real` but not [`Field`](crate::Field)/[`RealField`](crate::RealField).
///
/// [`RealField`](crate::RealField) is exactly a `Real` that is also a `Field`
/// (`RealField: Real + Field`), so every `RealField` value is a `Real` value, and
/// the concrete real scalars `f32`, `f64`, and `Float106` all implement `Real`.
///
/// Bound generic numeric code on `Real` (rather than `RealField`) when it needs only
/// the analytic operations; such code then also accepts non-field analytic types
/// like dual numbers.
pub trait Real:
    CommutativeRing + PartialOrd + Neg<Output = Self> + Copy + Clone + AddAssign + SubAssign + MulAssign
{
    /// Returns the `NaN` value.
    fn nan() -> Self;

    /// Returns `true` if this value is `NaN` and false otherwise.
    ///
    /// ```
    /// use deep_causality_num::Float;
    /// use core::f64;
    ///
    /// let nan = f64::NAN;
    /// let f = 7.0;
    ///
    /// assert!(nan.is_nan());
    /// assert!(!f.is_nan());
    /// ```
    fn is_nan(self) -> bool;

    /// Returns `true` if this value is positive infinity or negative infinity and
    /// false otherwise.
    ///
    /// ```
    /// use deep_causality_num::Float;
    /// use core::f32;
    ///
    /// let f = 7.0f32;
    /// let inf: f32 = Float::infinity();
    /// let neg_inf: f32 = Float::neg_infinity();
    /// let nan: f32 = f32::NAN;
    ///
    /// assert!(!f.is_infinite());
    /// assert!(!nan.is_infinite());
    ///
    /// assert!(inf.is_infinite());
    /// assert!(neg_inf.is_infinite());
    /// ```
    fn is_infinite(self) -> bool;

    /// Returns `true` if this number is neither infinite nor `NaN`.
    ///
    /// ```
    /// use deep_causality_num::Float;
    /// use core::f32;
    ///
    /// let f = 7.0f32;
    /// let inf: f32 = Float::infinity();
    /// let neg_inf: f32 = Float::neg_infinity();
    /// let nan: f32 = f32::NAN;
    ///
    /// assert!(f.is_finite());
    ///
    /// assert!(!nan.is_finite());
    /// assert!(!inf.is_finite());
    /// assert!(!neg_inf.is_finite());
    /// ```
    fn is_finite(self) -> bool;

    fn clamp(self, min: Self, max: Self) -> Self;

    /// Computes the principal square root of a number.
    /// For negative numbers, it returns `NaN`.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(4.0f64.sqrt(), 2.0);
    /// ```
    fn sqrt(self) -> Self;

    /// Computes the absolute value of a number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// let x = -4.0f64;
    /// assert_eq!(x.abs(), 4.0);
    /// ```
    fn abs(self) -> Self;

    /// Returns the largest integer less than or equal to a number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(2.99f64.floor(), 2.0);
    /// ```
    fn floor(self) -> Self;

    /// Returns the smallest integer greater than or equal to a number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(2.01f64.ceil(), 3.0);
    /// ```
    fn ceil(self) -> Self;

    /// Returns the nearest integer to a number. Rounds half-way cases away from 0.0.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(2.5f64.round(), 3.0);
    /// assert_eq!(-2.5f64.round(), -3.0);
    /// ```
    fn round(self) -> Self;

    /// Returns `e^(self)`, (the exponential function).
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// assert_eq!(1.0f64.exp(), consts::E);
    /// ```
    fn exp(self) -> Self;

    /// Returns the natural logarithm of the number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// assert_eq!(consts::E.ln(), 1.0);
    /// ```
    fn ln(self) -> Self;

    /// Returns the logarithm of the number with respect to an arbitrary base.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(8.0f64.log(2.0), 3.0);
    /// ```
    fn log(self, base: Self) -> Self;

    /// Returns the base-2 logarithm of the number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(8.0f64.log2(), 3.0);
    /// ```
    fn log2(self) -> Self;

    /// Returns the base-10 logarithm of the number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(1000.0f64.log10(), 3.0);
    /// ```
    fn log10(self) -> Self;

    /// Raises a number to a floating point power.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert_eq!(2.0f64.powf(3.0), 8.0);
    /// ```
    fn powf(self, n: Self) -> Self;

    /// Computes the sine of a number (in radians).
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// assert!((consts::PI / 2.0).sin() - 1.0 < 1e-9);
    /// ```
    fn sin(self) -> Self;

    /// Computes the arcsine of a number. Return value is in radians in the
    /// range [-pi/2, pi/2] or NaN if the number is outside the range [-1, 1].
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// let val = 1.0f64;
    /// assert!((val.asin() - consts::FRAC_PI_2).abs() < 1e-9);
    /// ```
    fn asin(self) -> Self;

    /// Computes the cosine of a number (in radians).
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// assert!((consts::PI.cos() - (-1.0)).abs() < 1e-9);
    /// ```
    fn cos(self) -> Self;

    /// Computes the arccosine of a number. Return value is in radians in the
    /// range [0, pi] or NaN if the number is outside the range [-1, 1].
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// let val = 1.0f64;
    /// assert!((val.acos() - 0.0).abs() < 1e-9);
    /// ```
    fn acos(self) -> Self;

    /// Computes the tangent of a number (in radians).
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// assert!((consts::FRAC_PI_4.tan() - 1.0).abs() < 1e-9);
    /// ```
    fn tan(self) -> Self;

    /// Computes the hyperbolic sine of a number.
    fn sinh(self) -> Self;

    /// Computes the hyperbolic cosine of a number.
    fn cosh(self) -> Self;

    /// Computes the hyperbolic tangent of a number.
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// assert!(0.0f64.tanh() == 0.0);
    /// ```
    fn tanh(self) -> Self;

    /// Computes the arctangent of a number. Return value is in radians in the
    /// range [-pi/2, pi/2];
    ///
    /// ```
    /// use deep_causality_algebra::Real;
    ///
    /// let f = 1.0;
    ///
    /// // atan(tan(1))
    /// let abs_difference = (f.tan().atan() - 1.0).abs();
    ///
    /// assert!(abs_difference < 1e-10);
    /// ```
    fn atan(self) -> Self;

    /// Computes the four-quadrant arctangent of `self` (y) and `other` (x).
    /// # Example
    /// ```
    /// use deep_causality_algebra::Real;
    /// use std::f64::consts;
    /// let y = 1.0f64;
    /// let x = -1.0f64;
    /// assert!((y.atan2(x) - (3.0 * consts::PI / 4.0)).abs() < 1e-9);
    /// ```
    fn atan2(self, other: Self) -> Self;

    /// Returns the constant π.
    fn pi() -> Self;

    /// Returns the Euler number e, the base of the natural logarithm.
    fn e() -> Self;

    /// Machine epsilon.
    /// Used for comparison comparisons to zero.
    fn epsilon() -> Self; // 1.19e-7 (f32) or 2.22e-16 (f64)
}

// Blanket implementation over all Floats

// Every `Float` is an analytic real scalar. The `Real` surface delegates to the
// corresponding `Float` operation, so a new float type implements `Float` and gets
// `Real` — and, via the other blanket impls, the whole algebra tower — for free.
impl<T: Float> Real for T {
    #[inline]
    fn nan() -> Self {
        Float::nan()
    }
    #[inline]
    fn is_nan(self) -> bool {
        Float::is_nan(self)
    }
    #[inline]
    fn is_infinite(self) -> bool {
        Float::is_infinite(self)
    }
    #[inline]
    fn is_finite(self) -> bool {
        Float::is_finite(self)
    }
    #[inline]
    fn clamp(self, min: Self, max: Self) -> Self {
        Float::clamp(self, min, max)
    }
    #[inline]
    fn sqrt(self) -> Self {
        Float::sqrt(self)
    }
    #[inline]
    fn abs(self) -> Self {
        Float::abs(self)
    }
    #[inline]
    fn floor(self) -> Self {
        Float::floor(self)
    }
    #[inline]
    fn ceil(self) -> Self {
        Float::ceil(self)
    }
    #[inline]
    fn round(self) -> Self {
        Float::round(self)
    }
    #[inline]
    fn exp(self) -> Self {
        Float::exp(self)
    }
    #[inline]
    fn ln(self) -> Self {
        Float::ln(self)
    }
    #[inline]
    fn log(self, base: Self) -> Self {
        Float::log(self, base)
    }
    #[inline]
    fn log2(self) -> Self {
        Float::log2(self)
    }
    #[inline]
    fn log10(self) -> Self {
        Float::log10(self)
    }
    #[inline]
    fn powf(self, n: Self) -> Self {
        Float::powf(self, n)
    }
    #[inline]
    fn sin(self) -> Self {
        Float::sin(self)
    }
    #[inline]
    fn asin(self) -> Self {
        Float::asin(self)
    }
    #[inline]
    fn cos(self) -> Self {
        Float::cos(self)
    }
    #[inline]
    fn acos(self) -> Self {
        Float::acos(self)
    }
    #[inline]
    fn tan(self) -> Self {
        Float::tan(self)
    }
    #[inline]
    fn sinh(self) -> Self {
        Float::sinh(self)
    }
    #[inline]
    fn cosh(self) -> Self {
        Float::cosh(self)
    }
    #[inline]
    fn tanh(self) -> Self {
        Float::tanh(self)
    }
    #[inline]
    fn atan(self) -> Self {
        Float::atan(self)
    }
    #[inline]
    fn atan2(self, other: Self) -> Self {
        Float::atan2(self, other)
    }
    #[inline]
    fn pi() -> Self {
        Float::pi()
    }
    #[inline]
    fn e() -> Self {
        Float::e()
    }
    #[inline]
    fn epsilon() -> Self {
        Float::epsilon()
    }
}
