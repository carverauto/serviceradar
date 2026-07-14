/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{Algebra, Ring};

/// Marker trait asserting that a bidirectional `From` conversion between `Self`
/// and `T` is an algebra homomorphism over a shared scalar ring `R`.
///
/// `AlgebraIso<T, R>` is the vector-structure-parallel counterpart of the
/// additive/multiplicative hierarchy ([`crate::iso::GroupIso<T>`] →
/// [`crate::iso::RingIso<T>`] → [`crate::iso::FieldIso<T>`]). It introduces a
/// second type parameter `R: Ring` for the scalar ring over which both `Self`
/// and `T` are algebras.
///
/// # Laws
///
/// 1. **Bidirectional From** (encoded in where-clause).
/// 2. **Round-trip identity** — `S::from(T::from(s)) == s` and the symmetric
///    case.
/// 3. **Module homomorphism (scalar multiplication preservation)** — for any
///    scalar `r: R` and vector `a: Self`, `T::from(a.scale(r)) == T::from(a).scale(r)`.
/// 4. **Algebra-product preservation** — `T::from(a * b) == T::from(a) * T::from(b)`
///    (the bilinear product of the algebra). For `Self` and `T` that are also
///    `Ring` and where the algebra product coincides with ring multiplication,
///    this overlaps with the `RingIso<T>` law; in general the two are
///    independent and both are part of the marker's promise.
///
/// The marker does not require `Self: Ring` or `T: Ring`. Implementers that
/// satisfy both a ring and an algebra structure typically write the marker
/// impls separately:
///
/// ```ignore
/// impl GroupIso<T> for S {}
/// impl RingIso<T> for S {}
/// impl AlgebraIso<T, R> for S {}
/// ```
///
/// Verified by [`crate::iso::test_support::assert_algebra_iso_from_law`].
///
/// # Inheritance
///
/// `AlgebraIso<T, R>` is extended by [`crate::iso::DivisionAlgebraIso<T, R>`]
/// when `R` is a `Field` and both `Self` and `T` are `DivisionAlgebra<R>`.
pub trait AlgebraIso<T, R>
where
    Self: Algebra<R> + From<T>,
    T: Algebra<R> + From<Self>,
    R: Ring,
{
}
