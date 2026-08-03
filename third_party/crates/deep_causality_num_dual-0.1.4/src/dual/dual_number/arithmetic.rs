/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Dual, Real};
use core::iter::{Product, Sum};
use core::ops::{Add, AddAssign, Div, Mul, MulAssign, Neg, Sub, SubAssign};

// Sum
impl<T: Real> Sum for Dual<T> {
    fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::new(T::zero(), T::zero()), |acc, x| acc + x)
    }
}

// Product
impl<T: Real> Product for Dual<T> {
    fn product<I: Iterator<Item = Self>>(iter: I) -> Self {
        iter.fold(Self::new(T::one(), T::zero()), |acc, x| acc * x)
    }
}

// Add: (a+bε) + (c+dε) = (a+c) + (b+d)ε
impl<T: Real> Add for Dual<T> {
    type Output = Self;
    #[inline]
    fn add(self, rhs: Self) -> Self {
        Self::new(self.re + rhs.re, self.du + rhs.du)
    }
}

impl<T: Real> AddAssign for Dual<T> {
    #[inline]
    fn add_assign(&mut self, rhs: Self) {
        self.re += rhs.re;
        self.du += rhs.du;
    }
}

// Sub: (a+bε) − (c+dε) = (a−c) + (b−d)ε
impl<T: Real> Sub for Dual<T> {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        Self::new(self.re - rhs.re, self.du - rhs.du)
    }
}

impl<T: Real> SubAssign for Dual<T> {
    #[inline]
    fn sub_assign(&mut self, rhs: Self) {
        self.re -= rhs.re;
        self.du -= rhs.du;
    }
}

// Mul (product/chain rule): (a+bε)(c+dε) = ac + (ad+bc)ε
impl<T: Real> Mul for Dual<T> {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self {
        Self::new(self.re * rhs.re, self.re * rhs.du + self.du * rhs.re)
    }
}

impl<T: Real> MulAssign for Dual<T> {
    #[inline]
    fn mul_assign(&mut self, rhs: Self) {
        let du = self.re * rhs.du + self.du * rhs.re;
        self.re *= rhs.re;
        self.du = du;
    }
}

// Negation: −(a+bε) = −a + (−b)ε
impl<T: Real> Neg for Dual<T> {
    type Output = Self;
    #[inline]
    fn neg(self) -> Self {
        Self::new(-self.re, -self.du)
    }
}

// Division (quotient rule): (a+bε)/(c+dε) = a/c + ((b·c − a·d)/c²)ε, for invertible `c`.
//
// `Dual` deliberately implements `Div` but **not** `DivAssign`: a dual has no total
// multiplicative inverse (`ε` is a zero divisor), so it must not be lifted to
// `InvMonoid`/`Field` by their blanket impls (which require `Div` *and* `DivAssign`).
// `Div` is only well-defined when the real part of the divisor is invertible.
impl<T: Real + Div<Output = T>> Div for Dual<T> {
    type Output = Self;
    #[inline]
    fn div(self, rhs: Self) -> Self {
        let denom = rhs.re * rhs.re;
        Self::new(
            self.re / rhs.re,
            (self.du * rhs.re - self.re * rhs.du) / denom,
        )
    }
}

// Scalar multiplication by `T` (the `Module<T>` action): (a+bε)·s = (a·s) + (b·s)ε
impl<T: Real> Mul<T> for Dual<T> {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: T) -> Self {
        Self::new(self.re * rhs, self.du * rhs)
    }
}

impl<T: Real> MulAssign<T> for Dual<T> {
    #[inline]
    fn mul_assign(&mut self, rhs: T) {
        self.re *= rhs;
        self.du *= rhs;
    }
}
