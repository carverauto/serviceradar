/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{Algebra, Field, Float};

/// Represents a **Division Algebra** over a `Field`.
///
/// A division algebra is an algebra over a field where every non-zero element `a`
/// has a multiplicative inverse, `a⁻¹`. This means that division is well-defined
/// (though not necessarily commutative or associative).
///
/// This trait is particularly useful for representing number systems like
/// real numbers, complex numbers, and quaternions.
///
/// # Mathematical Definition
///
/// An algebra `A` is a division algebra if for any element `a` in `A` and any
/// non-zero element `b` in `A`, the equations `a = bx` and `a = yb` have unique
/// solutions for `x` and `y`.
///
/// This implies the existence of multiplicative inverses for all non-zero elements.
pub trait DivisionAlgebra<R: Field>: Algebra<R> {
    /// Computes the conjugate of an element.
    ///
    /// In the context of algebras constructed via the Cayley-Dickson process
    /// (like Complex, Quaternions, Octonions), the conjugate of an element
    /// is found by negating its "imaginary" or vector parts.
    ///
    /// # Mathematical Properties
    /// - `(a*)* = a` (Involutive)
    /// - `(a + b)* = a* + b*`
    /// - `(a * b)* = b* * a*` (Anti-distributive)
    ///
    /// For real numbers, the conjugate is the identity function.
    fn conjugate(&self) -> Self;

    /// Computes the squared norm of an element.
    ///
    /// The squared norm is a scalar value from the base field `R`. For a normed
    /// division algebra, it is defined as `norm_sqr(a) = a * a.conjugate()`.
    /// This value is always real and non-negative.
    ///
    /// Using the squared norm is often more efficient than `norm()` as it avoids
    /// a square root operation.
    ///
    /// # Returns
    /// A scalar of type `R` from the base field.
    fn norm_sqr(&self) -> R;

    /// Computes the multiplicative inverse of an element.
    ///
    /// For a non-zero element `a`, its inverse `a⁻¹` is defined such that
    /// a * a⁻¹ = 1` and `a⁻¹ * a = 1`.
    ///
    /// In a normed division algebra, the inverse can be calculated as:
    /// `a⁻¹ = a.conjugate() / norm_sqr(a)`
    ///
    /// # Panics or Deviations
    ///
    /// If `self` is zero, `norm_sqr()` will be zero, leading to a division by zero.
    /// A correct implementation of this method should handle this case gracefully,
    /// typically by returning `NaN` or `Infinity` components, rather than panicking.
    fn inverse(&self) -> Self;
}

// Blanket implementation

/// Every `Float` is a division algebra over itself: the conjugate of a real number is
/// itself, the squared norm of `x` is `x*x`, and the inverse is `1/x` (`inf` at zero).
/// A new float type inherits this through `impl Float` — no per-type impl needed.
impl<T> DivisionAlgebra<T> for T
where
    T: Float,
{
    #[inline]
    fn conjugate(&self) -> Self {
        *self
    }

    #[inline]
    fn norm_sqr(&self) -> T {
        *self * *self
    }

    #[inline]
    fn inverse(&self) -> Self {
        Float::recip(*self)
    }
}
