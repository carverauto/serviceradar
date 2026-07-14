/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Integer;
use core::ops::Neg;

/// A trait for signed integer types.
///
/// Extends `Integer` with operations specific to signed types, such as
/// absolute value, signum, and negation.
///
/// # Mathematical Background
///
/// Signed integers represent $\mathbb{Z}$ (the integers) within a bounded range.
/// They support the additive inverse operation ($-a$), forming a true
/// additive group (unlike unsigned integers in standard arithmetic).
pub trait SignedInt: Integer + Neg<Output = Self> {
    /// Returns the absolute value of the integer.
    ///
    /// # Overflow
    /// For `MIN` values (e.g., `i8::MIN = -128`), the absolute value cannot
    /// be represented and will panic in debug mode or wrap in release.
    /// Use `checked_abs` for safe handling.
    fn abs(self) -> Self;

    /// Returns the sign of the integer.
    ///
    /// - `-1` if negative
    /// - `0` if zero
    /// - `1` if positive
    fn signum(self) -> Self;

    /// Returns `true` if the integer is negative.
    fn is_negative(self) -> bool;

    /// Returns `true` if the integer is positive.
    fn is_positive(self) -> bool;

    /// Checked absolute value. Returns `None` for `MIN`.
    fn checked_abs(self) -> Option<Self>;

    /// Checked negation. Returns `None` for `MIN`.
    fn checked_neg(self) -> Option<Self>;

    /// Saturating absolute value. Returns `MAX` for `MIN`.
    fn saturating_abs(self) -> Self;

    /// Wrapping absolute value. Wraps `MIN` to `MIN`.
    fn wrapping_abs(self) -> Self;

    /// Wrapping negation.
    fn wrapping_neg(self) -> Self;
}
