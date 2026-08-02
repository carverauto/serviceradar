/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Complex, RealField};
use core::iter::{Product, Sum};
use core::ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Neg, Sub, SubAssign};

// Implement Sum trait
impl<T: RealField> Sum for Complex<T> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::new(T::zero(), T::zero()), |acc, x| acc + x)
    }
}

// Implement Product trait
impl<T: RealField> Product for Complex<T> {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::new(T::one(), T::zero()), |acc, x| acc * x)
    }
}

// Add
impl<T: RealField> Add for Complex<T> {
    type Output = Self;
    #[inline]
    fn add(self, rhs: Self) -> Self {
        Self::new(self.re + rhs.re, self.im + rhs.im)
    }
}

// AddAssign
impl<T: RealField> AddAssign for Complex<T> {
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        self.re += rhs.re;
        self.im += rhs.im;
    }
}

// Scalar Add
impl<T: RealField> Add<T> for Complex<T> {
    type Output = Self;
    #[inline]
    fn add(self, rhs: T) -> Self {
        Self::new(self.re + rhs, self.im)
    }
}

// Scalar AddAssign
impl<T: RealField> AddAssign<T> for Complex<T> {
    #[inline]
    fn add_assign(&mut self, rhs: T) {
        self.re += rhs;
    }
}

// Sub
impl<T: RealField> Sub for Complex<T> {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.re - rhs.re, self.im - rhs.im)
    }
}

// SubAssign
impl<T: RealField> SubAssign for Complex<T> {
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        self.re -= rhs.re;
        self.im -= rhs.im;
    }
}

// Scalar Sub
impl<T: RealField> Sub<T> for Complex<T> {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: T) -> Self {
        Self::new(self.re - rhs, self.im)
    }
}

// Scalar SubAssign
impl<T: RealField> SubAssign<T> for Complex<T> {
    #[inline]
    fn sub_assign(&mut self, rhs: T) {
        self.re -= rhs;
    }
}

// Mul
impl<T: RealField> Mul for Complex<T> {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self {
        Self::new(
            self.re * rhs.re - self.im * rhs.im,
            self.re * rhs.im + self.im * rhs.re,
        )
    }
}

// MulAssign
impl<T: RealField> MulAssign for Complex<T> {
    #[inline]
    fn mul_assign(&mut self, rhs: Self) {
        let re = self.re * rhs.re - self.im * rhs.im;
        let im = self.re * rhs.im + self.im * rhs.re;
        self.re = re;
        self.im = im;
    }
}

// Scalar Mul
impl<T: RealField> Mul<T> for Complex<T> {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: T) -> Self {
        Self::new(self.re * rhs, self.im * rhs)
    }
}

// Scalar MulAssign
impl<T: RealField> MulAssign<T> for Complex<T> {
    #[inline]
    fn mul_assign(&mut self, rhs: T) {
        self.re *= rhs;
        self.im *= rhs;
    }
}

// Div
impl<T: RealField> Div for Complex<T> {
    type Output = Self;
    // Suppress False Positive lint
    // https://rust-lang.github.io/rust-clippy/rust-1.91.0/index.html#suspicious_arithmetic_impl
    #[allow(clippy::suspicious_arithmetic_impl)]
    #[inline]
    fn div(self, rhs: Self) -> Self {
        self * rhs._inverse_impl()
    }
}

// DivAssign
impl<T: RealField> DivAssign for Complex<T> {
    // Suppress False Positive lint
    #[allow(clippy::suspicious_op_assign_impl)]
    #[inline]
    fn div_assign(&mut self, rhs: Self) {
        *self *= rhs._inverse_impl();
    }
}

// Scalar Div
impl<T: RealField> Div<T> for Complex<T> {
    type Output = Self;
    #[inline]
    fn div(self, rhs: T) -> Self {
        Self::new(self.re / rhs, self.im / rhs)
    }
}

// Scalar DivAssign
impl<T: RealField> DivAssign<T> for Complex<T> {
    #[inline]
    fn div_assign(&mut self, rhs: T) {
        self.re /= rhs;
        self.im /= rhs;
    }
}

// Neg
impl<T: RealField> Neg for Complex<T> {
    type Output = Self;
    #[inline]
    fn neg(self) -> Self {
        Self::new(-self.re, -self.im)
    }
}
