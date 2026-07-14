/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Shared test types for the Field / Algebra / DivisionAlgebra iso tests.
//!
//! `FloatWrap` is a newtype around `f64` that satisfies the full algebraic
//! hierarchy used by the iso tests (`Field`, `Algebra<f64>`,
//! `DivisionAlgebra<f64>`). It serves as both source and target type for
//! identity-iso tests of the corresponding marker subtraits.
//!
//! `BadFieldWrap` is a similar newtype with a deliberately broken
//! `From<BadFieldWrap> for f64` (returns `value + 1.0`) so that homomorphism
//! assertions fail. Used in `#[should_panic]` tests across multiple files.
//!
//! These live under `src/utils_tests/` (not the `tests/` tree) so that Bazel's
//! per-file `rust_test_suite` compilation can reach them via the crate path
//! `deep_causality_algebra::utils_tests::utils_iso_tests` instead of a `tests/`
//! sibling module.

#![allow(dead_code)]

use crate::{AbelianGroup, Associative, Commutative, Distributive, DivisionAlgebra, One, Zero};
use core::ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Neg, Sub, SubAssign};

// ---------- FloatWrap: well-behaved identity iso to/from f64 ----------

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct FloatWrap(pub f64);

impl Add for FloatWrap {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        FloatWrap(self.0 + rhs.0)
    }
}

impl AddAssign for FloatWrap {
    fn add_assign(&mut self, rhs: Self) {
        self.0 += rhs.0;
    }
}

impl Sub for FloatWrap {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        FloatWrap(self.0 - rhs.0)
    }
}

impl SubAssign for FloatWrap {
    fn sub_assign(&mut self, rhs: Self) {
        self.0 -= rhs.0;
    }
}

impl Mul for FloatWrap {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        FloatWrap(self.0 * rhs.0)
    }
}

impl MulAssign for FloatWrap {
    fn mul_assign(&mut self, rhs: Self) {
        self.0 *= rhs.0;
    }
}

impl Div for FloatWrap {
    type Output = Self;
    fn div(self, rhs: Self) -> Self {
        FloatWrap(self.0 / rhs.0)
    }
}

impl DivAssign for FloatWrap {
    fn div_assign(&mut self, rhs: Self) {
        self.0 /= rhs.0;
    }
}

impl Neg for FloatWrap {
    type Output = Self;
    fn neg(self) -> Self {
        FloatWrap(-self.0)
    }
}

// Scalar multiplication by f64 (required for Module<f64> -> Algebra<f64>).
impl Mul<f64> for FloatWrap {
    type Output = Self;
    fn mul(self, rhs: f64) -> Self {
        FloatWrap(self.0 * rhs)
    }
}

impl MulAssign<f64> for FloatWrap {
    fn mul_assign(&mut self, rhs: f64) {
        self.0 *= rhs;
    }
}

impl Zero for FloatWrap {
    fn zero() -> Self {
        FloatWrap(0.0)
    }
    fn is_zero(&self) -> bool {
        self.0 == 0.0
    }
    fn set_zero(&mut self) {
        self.0 = 0.0;
    }
}

impl One for FloatWrap {
    fn one() -> Self {
        FloatWrap(1.0)
    }
    fn is_one(&self) -> bool {
        self.0 == 1.0
    }
}

impl Associative for FloatWrap {}
impl Commutative for FloatWrap {}
impl Distributive for FloatWrap {}

impl AbelianGroup for FloatWrap {}

// `InvMonoid` is blanket-implemented over types satisfying
// `MulMonoid + Div + DivAssign + One + Clone`; FloatWrap qualifies, so no
// manual impl is needed (and adding one would conflict).

impl DivisionAlgebra<f64> for FloatWrap {
    fn conjugate(&self) -> Self {
        // For real-valued division algebras, conjugation is the identity.
        *self
    }
    fn norm_sqr(&self) -> f64 {
        self.0 * self.0
    }
    fn inverse(&self) -> Self {
        FloatWrap(1.0 / self.0)
    }
}

impl From<f64> for FloatWrap {
    fn from(x: f64) -> Self {
        FloatWrap(x)
    }
}

impl From<FloatWrap> for f64 {
    fn from(w: FloatWrap) -> Self {
        w.0
    }
}

// Tier-1 identity-iso markers on the well-behaved `FloatWrap`. These live with
// the type (the orphan rule forbids implementing these foreign-to-the-test-crate
// traits on `FloatWrap` from the `tests/` tree once the type moved here). The
// corresponding `_iso_tests.rs` files assert the laws these markers claim.
impl crate::iso::GroupIso<f64> for FloatWrap {}
impl crate::iso::RingIso<f64> for FloatWrap {}
impl crate::iso::FieldIso<f64> for FloatWrap {}
impl crate::iso::AlgebraIso<f64, f64> for FloatWrap {}
impl crate::iso::DivisionAlgebraIso<f64, f64> for FloatWrap {}

// ---------- BadFieldWrap: identity From in one direction, +1.0 in the other ----------
//
// `f64::from(BadFieldWrap(x)) = x + 1.0`. This breaks every algebraic
// homomorphism law: addition, multiplication, inverse, scalar multiplication,
// conjugation. Used as the deliberately-broken iso for `#[should_panic]`
// tests that exercise the panic branches of every helper.

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct BadFieldWrap(pub f64);

impl Add for BadFieldWrap {
    type Output = Self;
    fn add(self, rhs: Self) -> Self {
        BadFieldWrap(self.0 + rhs.0)
    }
}

impl AddAssign for BadFieldWrap {
    fn add_assign(&mut self, rhs: Self) {
        self.0 += rhs.0;
    }
}

impl Sub for BadFieldWrap {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self {
        BadFieldWrap(self.0 - rhs.0)
    }
}

impl SubAssign for BadFieldWrap {
    fn sub_assign(&mut self, rhs: Self) {
        self.0 -= rhs.0;
    }
}

impl Mul for BadFieldWrap {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        BadFieldWrap(self.0 * rhs.0)
    }
}

impl MulAssign for BadFieldWrap {
    fn mul_assign(&mut self, rhs: Self) {
        self.0 *= rhs.0;
    }
}

impl Div for BadFieldWrap {
    type Output = Self;
    fn div(self, rhs: Self) -> Self {
        BadFieldWrap(self.0 / rhs.0)
    }
}

impl DivAssign for BadFieldWrap {
    fn div_assign(&mut self, rhs: Self) {
        self.0 /= rhs.0;
    }
}

impl Neg for BadFieldWrap {
    type Output = Self;
    fn neg(self) -> Self {
        BadFieldWrap(-self.0)
    }
}

impl Mul<f64> for BadFieldWrap {
    type Output = Self;
    fn mul(self, rhs: f64) -> Self {
        BadFieldWrap(self.0 * rhs)
    }
}

impl MulAssign<f64> for BadFieldWrap {
    fn mul_assign(&mut self, rhs: f64) {
        self.0 *= rhs;
    }
}

impl Zero for BadFieldWrap {
    fn zero() -> Self {
        BadFieldWrap(0.0)
    }
    fn is_zero(&self) -> bool {
        self.0 == 0.0
    }
    fn set_zero(&mut self) {
        self.0 = 0.0;
    }
}

impl One for BadFieldWrap {
    fn one() -> Self {
        BadFieldWrap(1.0)
    }
    fn is_one(&self) -> bool {
        self.0 == 1.0
    }
}

impl Associative for BadFieldWrap {}
impl Commutative for BadFieldWrap {}
impl Distributive for BadFieldWrap {}

impl AbelianGroup for BadFieldWrap {}

// `InvMonoid` is blanket-implemented; see comment on FloatWrap above.

impl DivisionAlgebra<f64> for BadFieldWrap {
    fn conjugate(&self) -> Self {
        // Broken: claim conjugation negates, which contradicts the wrapper's
        // From mapping. Forces the conjugation-preservation law to fail.
        BadFieldWrap(-self.0)
    }
    fn norm_sqr(&self) -> f64 {
        self.0 * self.0
    }
    fn inverse(&self) -> Self {
        BadFieldWrap(1.0 / self.0)
    }
}

impl From<f64> for BadFieldWrap {
    fn from(x: f64) -> Self {
        BadFieldWrap(x)
    }
}

impl From<BadFieldWrap> for f64 {
    fn from(w: BadFieldWrap) -> Self {
        // Broken: shift by 1.0 on the wrap -> f64 direction. Breaks all
        // homomorphism laws for the corresponding markers.
        w.0 + 1.0
    }
}
