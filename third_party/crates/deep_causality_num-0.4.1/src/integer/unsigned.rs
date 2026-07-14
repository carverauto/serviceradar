/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Integer;

/// A trait for unsigned integer types.
///
/// Extends `Integer` with operations and guarantees specific to unsigned types.
///
/// # Mathematical Background
///
/// Unsigned integers represent $\mathbb{N}_0$ (natural numbers including zero)
/// within a bounded range. They do NOT form an additive group under standard
/// arithmetic since subtraction can produce values outside the representable
/// range (negative numbers).
///
/// Under modular/wrapping arithmetic, they form $\mathbb{Z}/2^n\mathbb{Z}$, a ring.
pub trait UnsignedInt: Integer {
    /// Returns `true`. Provided for API consistency with `SignedInt`.
    #[inline]
    fn is_non_negative(self) -> bool {
        true
    }

    /// Returns the value unchanged. Provided for API consistency.
    ///
    /// For unsigned types, `abs(x) == x` always.
    #[inline]
    fn abs(self) -> Self
    where
        Self: Sized,
    {
        self
    }

    /// Returns the next power of two greater than or equal to `self`.
    ///
    /// Returns `None` if the result would overflow.
    fn checked_next_power_of_two(self) -> Option<Self>;

    /// Returns `true` if `self` is a power of two.
    fn is_power_of_two(self) -> bool;

    /// Returns the smallest power of two greater than or equal to `self`.
    ///
    /// # Panics
    /// Panics if the result would overflow.
    fn next_power_of_two(self) -> Self;
}
