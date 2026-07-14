/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{AbelianGroup, Ring};
use core::ops::{Mul, MulAssign};

/// Represents a **Module** over a `Ring`.
///
/// A module is a generalization of a vector space, where the scalars are
/// elements of a `Ring` `R` rather than being restricted to a `Field`.
///
/// # Mathematical Definition
///
/// A left module `M` over a ring `R` consists of an abelian group `(M, +)` and
/// an operation `R × M → M` (scalar multiplication) such that for all
/// `r, s` in `R` and `x, y` in `M`, the following axioms hold:
///
/// 1.  `r * (x + y) = r*x + r*y`
/// 2.  `(r + s) * x = r*x + s*x`
/// 3.  `(r * s) * x = r * (s * x)`
/// 4.  `1 * x = x` (if `R` is a unital ring)
///
/// ## Structure in this Crate
/// -   The "vectors" (`Self`) form an `AbelianGroup`.
/// -   The "scalars" (`R`) form a `Ring`.
/// -   Scalar multiplication is provided by implementing `Mul<R>` and `MulAssign<R>`.
///
/// ## Examples
/// -   Any `AbelianGroup` `G` is a module over the ring of integers `Z`.
/// -   A vector space is a module where the ring of scalars is a `Field`.
/// -   `Complex<T>` is a module over the `RealField` `T`.
pub trait Module<R: Ring>: AbelianGroup + Mul<R, Output = Self> + MulAssign<R> {
    /// Scales the module element by a scalar from the ring `R`.
    ///
    /// This is a convenience method that clones `self` and applies the `*`
    /// operator for scalar multiplication.
    ///
    /// # Arguments
    /// * `scalar`: The scalar value of type `R` to multiply by.
    ///
    /// # Returns
    /// A new element of `Self` representing the scaled result.
    fn scale(&self, scalar: R) -> Self {
        // We must clone because `Mul` usually consumes `self` (value semantics),
        // but `scale` takes `&self` (reference semantics).
        // We know Self is Clone because AbelianGroup -> AddGroup -> Clone.
        self.clone() * scalar
    }

    /// Scales the module element in-place by a scalar from the ring `R`.
    ///
    /// This is a convenience method that uses the `MulAssign` (`*=`) operator
    /// for in-place scalar multiplication. This is often more efficient for
    /// large data structures like tensors as it avoids allocation.
    ///
    /// # Arguments
    /// * `scalar`: The scalar value of type `R` to multiply by.
    fn scale_mut(&mut self, scalar: R) {
        *self *= scalar; // Uses MulAssign
    }
}

// Blanket implementation for any type that satisfies the bounds
impl<V, R> Module<R> for V
where
    V: AbelianGroup + Mul<R, Output = V> + MulAssign<R>,
    R: Ring,
{
}
