/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CommutativeRing;
use core::ops::Div;

/// Represents a **Euclidean Domain**.
///
/// A Euclidean domain is an integral domain equipped with a Euclidean function
/// that enables division with remainder. This is the foundation of the
/// Euclidean algorithm for computing greatest common divisors.
///
/// # Mathematical Definition
///
/// A commutative ring `R` is a Euclidean domain if there exists a function
/// `φ: R \ {0} → ℕ` (the Euclidean function) such that for any `a, b ∈ R`
/// with `b ≠ 0`, there exist `q, r ∈ R` satisfying:
///
/// 1. `a = b·q + r`
/// 2. Either `r = 0` or `φ(r) < φ(b)`
///
/// For integers, `φ(n) = |n|` (absolute value).
///
/// # Properties
/// - Every Euclidean domain is a Principal Ideal Domain (PID).
/// - Every Euclidean domain is a Unique Factorization Domain (UFD).
/// - The Euclidean algorithm terminates in finite steps.
///
/// # Examples
/// - Integers `ℤ` with `φ(n) = |n|`
/// - Gaussian integers `ℤ[i]` with `φ(a + bi) = a² + b²`
/// - Polynomial rings `F[x]` over a field with `φ(p) = deg(p)`
pub trait EuclideanDomain: CommutativeRing {
    /// The Euclidean function value type (typically a measure of "size").
    /// For integers, this is the absolute value.
    type EuclideanValue: Ord;

    /// Computes the Euclidean function value.
    ///
    /// For integers, this returns the absolute value.
    /// For polynomials, this would return the degree.
    fn euclidean_fn(&self) -> Self::EuclideanValue;

    /// Computes the quotient of Euclidean division.
    ///
    /// For `a.div_euclid(b)`, returns `q` such that `a = b*q + r`
    /// where `0 ≤ r < |b|`.
    fn div_euclid(&self, other: &Self) -> Self;

    /// Computes the remainder of Euclidean division.
    ///
    /// For `a.rem_euclid(b)`, returns `r` such that `a = b*q + r`
    /// where `0 ≤ r < |b|`.
    ///
    /// Unlike the `%` operator, the result is always non-negative.
    fn rem_euclid(&self, other: &Self) -> Self;

    /// Computes the greatest common divisor using the Euclidean algorithm.
    ///
    /// # Properties
    /// - `gcd(a, 0) = |a|`
    /// - `gcd(a, b) = gcd(b, a % b)`
    /// - `gcd(a, b)` divides both `a` and `b`
    /// - Any common divisor of `a` and `b` also divides `gcd(a, b)`
    fn gcd(&self, other: &Self) -> Self
    where
        Self: Sized + Clone,
    {
        let mut a = self.clone();
        let mut b = other.clone();
        while !b.is_zero() {
            let r = a.rem_euclid(&b);
            a = b;
            b = r;
        }
        a
    }

    /// Computes the least common multiple.
    ///
    /// `lcm(a, b) = |a * b| / gcd(a, b)`
    fn lcm(&self, other: &Self) -> Self
    where
        Self: Sized + Clone + Div<Output = Self>,
    {
        if self.is_zero() || other.is_zero() {
            return Self::zero();
        }
        let g = self.gcd(other);
        // |a * b| / gcd(a, b)
        self.clone() * other.clone() / g
    }
}

// -----------------------------------------------------------------------------
// Signed Integer Implementations
// -----------------------------------------------------------------------------

impl EuclideanDomain for i8 {
    type EuclideanValue = u8;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        i8::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        i8::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for i16 {
    type EuclideanValue = u16;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        i16::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        i16::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for i32 {
    type EuclideanValue = u32;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        i32::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        i32::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for i64 {
    type EuclideanValue = u64;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        i64::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        i64::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for i128 {
    type EuclideanValue = u128;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        i128::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        i128::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for isize {
    type EuclideanValue = usize;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        self.unsigned_abs()
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        isize::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        isize::rem_euclid(*self, *other)
    }
}

// -----------------------------------------------------------------------------
// Unsigned Integer Implementations
// -----------------------------------------------------------------------------

impl EuclideanDomain for u8 {
    type EuclideanValue = u8;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        u8::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        u8::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for u16 {
    type EuclideanValue = u16;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        u16::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        u16::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for u32 {
    type EuclideanValue = u32;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        u32::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        u32::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for u64 {
    type EuclideanValue = u64;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        u64::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        u64::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for u128 {
    type EuclideanValue = u128;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        u128::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        u128::rem_euclid(*self, *other)
    }
}

impl EuclideanDomain for usize {
    type EuclideanValue = usize;

    #[inline]
    fn euclidean_fn(&self) -> Self::EuclideanValue {
        *self
    }

    #[inline]
    fn div_euclid(&self, other: &Self) -> Self {
        usize::div_euclid(*self, *other)
    }

    #[inline]
    fn rem_euclid(&self, other: &Self) -> Self {
        usize::rem_euclid(*self, *other)
    }
}
