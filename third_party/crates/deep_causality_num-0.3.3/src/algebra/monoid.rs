/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Associative, MulMagma, One, Zero};
use core::ops::{Add, AddAssign, Div, DivAssign};

/// Represents an **Additive Monoid**.
///
/// A monoid is an algebraic structure with a single associative binary
/// operation and an identity element. An additive monoid is one where the
/// operation is addition (`+`).
///
/// # Mathematical Definition
///
/// A set `S` with a binary operation `+` is an additive monoid if it satisfies:
/// 1.  **Closure:** `a + b` is in `S`. (Implicit in Rust).
/// 2.  **Associativity:** `(a + b) + c = a + (b + c)` for all `a, b, c` in `S`.
///     (A property the implementor must uphold).
/// 3.  **Identity Element:** There exists an element `0` in `S` such that
///     `a + 0 = 0 + a = a` for all `a` in `S`. (Provided by the `Zero` trait).
///
/// The `Clone` and `AddAssign` bounds are included for practical purposes.
pub trait AddMonoid: Add<Output = Self> + AddAssign + Zero + Clone {}

// Blanket Implementation for all types that implement Add, AddAssign, and Zero
impl<T> AddMonoid for T where T: Add<Output = Self> + AddAssign + Zero + Clone {}

/// Represents a **Multiplicative Monoid**.
///
/// A monoid is an algebraic structure with a single associative binary
/// operation and an identity element. A multiplicative monoid is one where the
/// operation is multiplication (`*`).
///
/// # Mathematical Definition
///
/// A set `S` with a binary operation `*` is a multiplicative monoid if it satisfies:
/// 1.  **Closure:** `a * b` is in `S`. (Implicit in Rust).
/// 2.  **Associativity:** `(a * b) * c = a * (b * c)` for all `a, b, c` in `S`.
///     (A property the implementor must uphold).
/// 3.  **Identity Element:** There exists an element `1` in `S` such that
///     `a * 1 = 1 * a = a` for all `a` in `S`. (Provided by the `One` trait).
///
/// The `Clone` and `MulAssign` bounds are included for practical purposes.
pub trait MulMonoid: MulMagma + One + Associative {}

// Blanket Implementation for all types that implement Mul, MulAssign, and One
impl<T> MulMonoid for T where T: MulMagma + One + Associative {}

/// Represents a **Multiplicative Monoid** with the additional property
/// that every element has a multiplicative inverse.
///
/// This trait effectively defines the "inverse" operation within a multiplicative
/// context, sitting between `MulMonoid` and `MulGroup` in the hierarchy.
///
/// # Mathematical Definition
///
/// An `InvMonoid` is a `MulMonoid` where for every element `a`, there exists
/// an element `a⁻¹` such that `a * a⁻¹ = 1` and `a⁻¹ * a = 1`.
///
/// # Justification for Deviation (for floating-point types)
///
/// In pure mathematics, the zero element does not have a multiplicative inverse.
/// To align with standard floating-point behavior (IEEE 754), implementations
/// for types that can be zero (like `f32`, `f64`) should handle this case
/// gracefully by returning `Infinity` or `NaN` rather than panicking.
pub trait InvMonoid: MulMonoid + Div<Output = Self> + DivAssign {
    /// Computes the multiplicative inverse of an element.
    ///
    /// For a non-zero element `a`, its inverse `a⁻¹` is the unique element
    /// such that `a * a⁻¹ = 1`.
    fn inverse(&self) -> Self;
}

// Blanket Implementation for types that already satisfy MulMonoid and
// implement Div and DivAssign. This blanket assumes a standard inverse
// calculation using 1 / self.
impl<T> InvMonoid for T
where
    T: MulMonoid + Div<Output = Self> + DivAssign + One + Clone,
{
    #[inline]
    fn inverse(&self) -> Self {
        // The inverse is typically defined as Identity / Value.
        // We utilize the Div trait which is required by InvMonoid.
        // We clone self because Div takes operands by value (T / T).
        // For Copy types like f64/Complex, clone() is a no-op copy.
        T::one() / self.clone()
    }
}
