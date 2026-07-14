/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::RealField;

mod algebra;
mod arithmetic;
mod cast;
mod display;
mod identity;
mod ops;
mod ops_shared;
mod rotation;

/// Represents a complex number with real and imaginary parts.
///
/// A complex number is a number that can be expressed in the form `a + bi`,
/// where `a` and `b` are real numbers, and `i` is the imaginary unit,
/// satisfying the equation `i^2 = -1`.
///
/// The `Complex` struct is generic over a type `T` that implements `RealField`,
/// allowing it to work with different floating-point precisions (e.g., `f32` or `f64`).
///
/// # Fields
///
/// * `re`: The real part of the complex number.
/// * `im`: The imaginary part of the complex number.
///
/// # Examples
///
/// ```
/// use deep_causality_num::Complex;
///
/// let c1 = Complex::new(1.0, 2.0); // Represents 1.0 + 2.0i
/// let c2 = Complex { re: 3.0, im: -1.0 }; // Represents 3.0 - 1.0i
///
/// assert_eq!(c1.re, 1.0);
/// assert_eq!(c2.im, -1.0);
/// ```
#[derive(Copy, Clone, PartialEq, Default, Debug)]
pub struct Complex<T: RealField> {
    pub re: T,
    pub im: T,
}

impl<T: RealField> Eq for Complex<T> {}

impl<T: RealField> PartialOrd for Complex<T> {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        match self.re.partial_cmp(&other.re) {
            Some(core::cmp::Ordering::Equal) => self.im.partial_cmp(&other.im),
            ord => ord,
        }
    }
}

impl<T: RealField + Ord> Ord for Complex<T> {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        match self.re.cmp(&other.re) {
            core::cmp::Ordering::Equal => self.im.cmp(&other.im),
            ord => ord,
        }
    }
}

pub type Complex32 = Complex<f32>;
pub type Complex64 = Complex<f64>;

impl<T: RealField> Complex<T> {
    /// Creates a new complex number from its real and imaginary parts.
    #[inline]
    pub fn new(re: T, im: T) -> Self {
        Self { re, im }
    }

    /// Creates a new complex number from a real number.
    #[inline]
    pub fn from_real(re: T) -> Self {
        Self { re, im: T::zero() }
    }
}

impl<T: RealField> Complex<T> {
    /// Returns the real part of the complex number.
    #[inline]
    pub fn re(&self) -> T {
        self.re
    }

    /// Returns the imaginary part of the complex number.
    #[inline]
    pub fn im(&self) -> T {
        self.im
    }
}
