/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use core::ops::Mul;

/// Defines a multiplicative identity element for `Self`.
///
/// # Laws
///
/// ```text
/// a * 1 = a       ∀ a ∈ Self
/// 1 * a = a       ∀ a ∈ Self
/// ```
pub trait One: Sized + Mul<Self, Output = Self> {
    /// Returns the multiplicative identity element of `Self`, `1`.
    ///
    /// # Purity
    ///
    /// This function should return the same result at all times regardless of
    /// external mutable state.
    // This cannot be an associated constant, because of bignums.
    fn one() -> Self;

    /// Sets `self` to the multiplicative identity element of `Self`, `1`.
    fn set_one(&mut self) {
        *self = One::one();
    }

    /// Returns `true` if `self` is equal to the multiplicative identity.
    fn is_one(&self) -> bool;
}

/// Defines an associated constant representing the multiplicative identity
/// element for `Self`.
pub trait ConstOne: One {
    /// The multiplicative identity element of `Self`, `1`.
    const ONE: Self;
}
