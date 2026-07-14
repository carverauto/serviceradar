/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! This module defines the `Octonion` struct and its core implementations, providing
//! a robust representation and arithmetic for octonion numbers.
//!
//! # Octonion Numbers
//! Octonions are a non-associative, non-commutative extension of quaternion numbers,
//! forming an 8-dimensional normed division algebra over the real numbers.
//! An octonion can be expressed in the form:
//!
//! `s + e₁i + e₂j + e₃k + e₄l + e₅m + e₆n + e₇p`
//!
//! where `s` is the scalar part and `e₁` through `e₇` are the imaginary (vector) parts,
//! each multiplied by an imaginary unit. These imaginary units satisfy specific
//! multiplication rules, which are typically represented by a Fano plane or a
//! multiplication table.
//!
//! # Cayley-Dickson Construction
//! The multiplication rules for octonions implemented in this module follow the
//! Cayley-Dickson construction. This construction defines a doubling process
//! that generates complex numbers from real numbers, quaternions from complex numbers,
//! and octonions from quaternions. Key properties of octonion multiplication include:
//!
//! - **Non-commutativity:** For two octonions `a` and `b`, `a * b ≠ b * a` in general.
//! - **Non-associativity:** For three octonions `a`, `b`, and `c`, `(a * b) * c ≠ a * (b * c)` in general.
//!
//! Despite these differences from more familiar number systems, octonions retain
//! properties such as distributivity over addition and an inverse for every non-zero octonion.
//!
//! The multiplication table, based on the Fano plane, defines how the imaginary units
//! multiply. A common representation (used here) is:
//!
//! - `eᵢ * eᵢ = -1` for `i = 1..7`
//! - `e₁ * e₂ = e₃`, `e₂ * e₁ = -e₃`
//! - `e₁ * e₃ = -e₂`, `e₃ * e₁ = e₂`
//! - `e₆ * e₇ = e₁`, `e₇ * e₆ = -e₁`
//!
//! These rules are meticulously applied in the `Mul` implementation for the `Octonion` struct.
//!
//! # Structure
//! The `Octonion` struct is a generic representation, parameterized by a floating-point type `F`.
//! It holds eight components: `s` (scalar) and `e1` through `e7` (imaginary units).
//!
use crate::RealField;

mod algebra;
mod arithmetic;
mod cast;
mod debug;
mod display;
mod identity;
mod neg;
mod ops;
mod ops_shared;
mod rotation;

/// Represents an octonion number with a scalar part and seven imaginary parts.
///
/// An octonion is an 8-dimensional hypercomplex number, extending quaternions.
/// It consists of a scalar component `s` and seven imaginary components `e1` through `e7`.
///
/// # Type Parameters
/// * `F` - The floating-point type used for the components of the octonion (e.g., `f32`, `f64`).
///
/// # Fields
/// * `s` - The scalar (real) part of the octonion.
/// * `e1` - The coefficient of the first imaginary unit.
/// * `e2` - The coefficient of the second imaginary unit.
/// * `e3` - The coefficient of the third imaginary unit.
/// * `e4` - The coefficient of the fourth imaginary unit.
/// * `e5` - The coefficient of the fifth imaginary unit.
/// * `e6` - The coefficient of the sixth imaginary unit.
/// * `e7` - The coefficient of the seventh imaginary unit.
///
/// # Derives
/// * `Copy`: Allows instances of `Octonion` to be copied by bitwise copy.
/// * `Clone`: Implements cloning behavior for `Octonion`.
/// * `Default`: Provides a default (zero) value for `Octonion`.
#[derive(Copy, Clone, PartialEq, PartialOrd, Default)]
pub struct Octonion<F>
where
    F: RealField,
{
    pub s: F,  // Scalar part
    pub e1: F, // Imaginary unit 1
    pub e2: F, // Imaginary unit 2
    pub e3: F, // Imaginary unit 3
    pub e4: F, // Imaginary unit 4
    pub e5: F, // Imaginary unit 5
    pub e6: F, // Imaginary unit 6
    pub e7: F, // Imaginary unit 7
}

pub type Octonion32 = Octonion<f32>;
pub type Octonion64 = Octonion<f64>;

impl<F> Octonion<F>
where
    F: RealField,
{
    /// Creates a new `Octonion` from its eight scalar components.
    ///
    /// # Arguments
    /// * `s` - The scalar (real) part.
    /// * `e1` - The coefficient of the first imaginary unit.
    /// * `e2` - The coefficient of the second imaginary unit.
    /// * `e3` - The coefficient of the third imaginary unit.
    /// * `e4` - The coefficient of the fourth imaginary unit.
    /// * `e5` - The coefficient of the fifth imaginary unit.
    /// * `e6` - The coefficient of the sixth imaginary unit.
    /// * `e7` - The coefficient of the seventh imaginary unit.
    ///
    /// # Returns
    /// A new `Octonion` instance.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    ///
    /// let o = Octonion::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
    /// assert_eq!(o.s, 1.0);
    /// assert_eq!(o.e7, 8.0);
    /// ```
    #[allow(clippy::too_many_arguments)]
    pub fn new(s: F, e1: F, e2: F, e3: F, e4: F, e5: F, e6: F, e7: F) -> Self {
        Self {
            s,
            e1,
            e2,
            e3,
            e4,
            e5,
            e6,
            e7,
        }
    }
    /// Creates a new `Octonion` from a single real (scalar) value.
    ///
    /// The real value populates the scalar part (`s`) of the octonion, and all
    /// imaginary parts (`e1` through `e7`) are set to zero.
    ///
    /// # Arguments
    /// * `re` - The real scalar value.
    ///
    /// # Returns
    /// A new `Octonion` instance representing a real number.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::Zero;
    ///
    /// let o = Octonion::from_real(5.0);
    /// assert_eq!(o.s, 5.0);
    /// assert!(o.e1.is_zero());
    /// assert!(o.e7.is_zero());
    /// ```
    pub fn from_real(re: F) -> Self {
        Self {
            s: re,
            e1: F::zero(),
            e2: F::zero(),
            e3: F::zero(),
            e4: F::zero(),
            e5: F::zero(),
            e6: F::zero(),
            e7: F::zero(),
        }
    }

    /// Returns the identity octonion (1 + 0e₁ + ... + 0e₇).
    ///
    /// The identity octonion has a scalar part of 1 and all imaginary parts are 0.
    /// When multiplied by any other octonion, it returns the other octonion.
    ///
    /// # Returns
    /// The identity `Octonion` instance.
    ///
    /// # Examples
    /// ```
    /// use deep_causality_num::Octonion;
    /// use deep_causality_num::{One, Zero};
    ///
    /// let identity: Octonion<f64> = Octonion::identity();
    /// assert_eq!(identity.s, 1.0);
    /// assert!(identity.e1.is_zero());
    /// assert!(identity.e7.is_zero());
    ///
    /// // The identity is also accessible via the One trait
    /// assert_eq!(identity, Octonion::one());
    /// ```
    pub fn identity() -> Self {
        Self {
            s: F::one(),
            e1: F::zero(),
            e2: F::zero(),
            e3: F::zero(),
            e4: F::zero(),
            e5: F::zero(),
            e6: F::zero(),
            e7: F::zero(),
        }
    }
}
