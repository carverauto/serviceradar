/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Arithmetic operations for `DoubleFloat` using Error-Free Transformations.

use crate::float_106::{Float106, quick_two_sum, two_prod, two_sum};
use core::ops::{
    Add, AddAssign, Div, DivAssign, Mul, MulAssign, Neg, Rem, RemAssign, Sub, SubAssign,
};

// =============================================================================
// Negation
// =============================================================================

impl Neg for Float106 {
    type Output = Self;

    #[inline]
    fn neg(self) -> Self::Output {
        Self {
            hi: -self.hi,
            lo: -self.lo,
        }
    }
}

// =============================================================================
// Addition
// =============================================================================

impl Add for Float106 {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        // Sloppy addition: O(1) algorithm with ~2^-104 relative error
        let (s1, s2) = two_sum(self.hi, rhs.hi);
        let t1 = self.lo + rhs.lo;
        let t2 = s2 + t1;
        let (hi, lo) = quick_two_sum(s1, t2);
        Self::new(hi, lo)
    }
}

impl Add<f64> for Float106 {
    type Output = Self;

    #[inline]
    fn add(self, rhs: f64) -> Self::Output {
        self + Self::from_f64(rhs)
    }
}

impl Add<Float106> for f64 {
    type Output = Float106;

    #[inline]
    fn add(self, rhs: Float106) -> Self::Output {
        Float106::from_f64(self) + rhs
    }
}

impl AddAssign for Float106 {
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        *self = *self + rhs;
    }
}

impl AddAssign<f64> for Float106 {
    #[inline]
    fn add_assign(&mut self, rhs: f64) {
        *self = *self + rhs;
    }
}

// =============================================================================
// Subtraction
// =============================================================================

impl Sub for Float106 {
    type Output = Self;

    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        // a - b = a + (-b)
        // Negation is exact, so this preserves EFT properties.
        self + (-rhs)
    }
}

impl Sub<f64> for Float106 {
    type Output = Self;

    #[inline]
    fn sub(self, rhs: f64) -> Self::Output {
        self - Self::from_f64(rhs)
    }
}

impl Sub<Float106> for f64 {
    type Output = Float106;

    #[inline]
    fn sub(self, rhs: Float106) -> Self::Output {
        Float106::from_f64(self) - rhs
    }
}

impl SubAssign for Float106 {
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        *self = *self - rhs;
    }
}

impl SubAssign<f64> for Float106 {
    #[inline]
    fn sub_assign(&mut self, rhs: f64) {
        *self = *self - rhs;
    }
}

// =============================================================================
// Multiplication
// =============================================================================

impl Mul for Float106 {
    type Output = Self;

    fn mul(self, rhs: Self) -> Self::Output {
        // C = A * B
        // p1, p2 = two_prod(a.hi, b.hi)
        let (p1, p2) = two_prod(self.hi, rhs.hi);

        // p2 += a.hi * b.lo + a.lo * b.hi
        // The term a.lo * b.lo is O(ulp^2) and negligible
        let t = p2 + self.hi * rhs.lo + self.lo * rhs.hi;

        let (hi, lo) = quick_two_sum(p1, t);
        Self::new(hi, lo)
    }
}

impl Mul<f64> for Float106 {
    type Output = Self;

    fn mul(self, rhs: f64) -> Self::Output {
        // Optimized: single f64 multiply
        let (p1, p2) = two_prod(self.hi, rhs);
        let t = p2 + self.lo * rhs;
        let (hi, lo) = quick_two_sum(p1, t);
        Self::new(hi, lo)
    }
}

impl Mul<Float106> for f64 {
    type Output = Float106;

    #[inline]
    fn mul(self, rhs: Float106) -> Self::Output {
        rhs * self
    }
}

impl MulAssign for Float106 {
    #[inline]
    fn mul_assign(&mut self, rhs: Self) {
        *self = *self * rhs;
    }
}

impl MulAssign<f64> for Float106 {
    #[inline]
    fn mul_assign(&mut self, rhs: f64) {
        *self = *self * rhs;
    }
}

// =============================================================================
// Division
// =============================================================================

impl Div for Float106 {
    type Output = Self;

    fn div(self, rhs: Self) -> Self::Output {
        // High-precision division using iterative refinement.
        // q1 = a.hi / b.hi
        let q1 = self.hi / rhs.hi;

        // r = a - q1 * b
        // Compute (a.hi - q1 * b.hi) carefully using two_prod
        let (p1, p2) = two_prod(q1, rhs.hi);
        let s = self.hi - p1;
        let t = (s - p2) + self.lo - q1 * rhs.lo;

        // q2 = t / b.hi
        let q2 = t / rhs.hi;

        let (hi, lo) = quick_two_sum(q1, q2);
        Self::new(hi, lo)
    }
}

impl Div<f64> for Float106 {
    type Output = Self;

    fn div(self, rhs: f64) -> Self::Output {
        // Optimized: single f64 divisor
        let q1 = self.hi / rhs;
        let (p1, p2) = two_prod(q1, rhs);
        let s = self.hi - p1;
        let t = (s - p2) + self.lo;
        let q2 = t / rhs;
        let (hi, lo) = quick_two_sum(q1, q2);
        Self::new(hi, lo)
    }
}

impl Div<Float106> for f64 {
    type Output = Float106;

    #[inline]
    fn div(self, rhs: Float106) -> Self::Output {
        Float106::from_f64(self) / rhs
    }
}

impl DivAssign for Float106 {
    #[inline]
    fn div_assign(&mut self, rhs: Self) {
        *self = *self / rhs;
    }
}

impl DivAssign<f64> for Float106 {
    #[inline]
    fn div_assign(&mut self, rhs: f64) {
        *self = *self / rhs;
    }
}

// =============================================================================
// Remainder
// =============================================================================

impl Rem for Float106 {
    type Output = Self;

    fn rem(self, rhs: Self) -> Self::Output {
        // r = a - n * b, where n = trunc(a / b)
        let div = self / rhs;
        #[cfg(feature = "std")]
        let n = div.hi.trunc();
        #[cfg(all(not(feature = "std"), feature = "libm_math"))]
        let n = libm::trunc(div.hi);
        self - (rhs * Self::from_f64(n))
    }
}

impl Rem<f64> for Float106 {
    type Output = Self;

    #[inline]
    fn rem(self, rhs: f64) -> Self::Output {
        self % Self::from_f64(rhs)
    }
}

impl Rem<Float106> for f64 {
    type Output = Float106;

    #[inline]
    fn rem(self, rhs: Float106) -> Self::Output {
        Float106::from_f64(self) % rhs
    }
}

impl RemAssign for Float106 {
    #[inline]
    fn rem_assign(&mut self, rhs: Self) {
        *self = *self % rhs;
    }
}

impl RemAssign<f64> for Float106 {
    #[inline]
    fn rem_assign(&mut self, rhs: f64) {
        *self = *self % rhs;
    }
}

// =============================================================================
// Reference Operations
// =============================================================================

impl Add<&Float106> for Float106 {
    type Output = Self;

    #[inline]
    fn add(self, rhs: &Float106) -> Self::Output {
        self + *rhs
    }
}

impl Add<Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn add(self, rhs: Float106) -> Self::Output {
        *self + rhs
    }
}

impl Add<&Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn add(self, rhs: &Float106) -> Self::Output {
        *self + *rhs
    }
}

impl Sub<&Float106> for Float106 {
    type Output = Self;

    #[inline]
    fn sub(self, rhs: &Float106) -> Self::Output {
        self - *rhs
    }
}

impl Sub<Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn sub(self, rhs: Float106) -> Self::Output {
        *self - rhs
    }
}

impl Sub<&Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn sub(self, rhs: &Float106) -> Self::Output {
        *self - *rhs
    }
}

impl Mul<&Float106> for Float106 {
    type Output = Self;

    #[inline]
    fn mul(self, rhs: &Float106) -> Self::Output {
        self * *rhs
    }
}

impl Mul<Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn mul(self, rhs: Float106) -> Self::Output {
        *self * rhs
    }
}

impl Mul<&Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn mul(self, rhs: &Float106) -> Self::Output {
        *self * *rhs
    }
}

impl Div<&Float106> for Float106 {
    type Output = Self;

    #[inline]
    fn div(self, rhs: &Float106) -> Self::Output {
        self / *rhs
    }
}

impl Div<Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn div(self, rhs: Float106) -> Self::Output {
        *self / rhs
    }
}

impl Div<&Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn div(self, rhs: &Float106) -> Self::Output {
        *self / *rhs
    }
}

impl Rem<&Float106> for Float106 {
    type Output = Self;

    #[inline]
    fn rem(self, rhs: &Float106) -> Self::Output {
        self % *rhs
    }
}

impl Rem<Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn rem(self, rhs: Float106) -> Self::Output {
        *self % rhs
    }
}

impl Rem<&Float106> for &Float106 {
    type Output = Float106;

    #[inline]
    fn rem(self, rhs: &Float106) -> Self::Output {
        *self % *rhs
    }
}
