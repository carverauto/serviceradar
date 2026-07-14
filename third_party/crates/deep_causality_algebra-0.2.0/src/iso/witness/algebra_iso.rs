/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::iso::witness::iso::Iso;
use crate::{Algebra, Ring};

/// Marker trait asserting that an `Iso<S, T>` preserves algebra-over-ring
/// structure on the type pair `(S, T, R)` — scalar multiplication by `R` and
/// the algebra product.
///
/// `AlgebraIso<S, T, R>` is the vector-structure-parallel of the
/// additive/multiplicative hierarchy ([`GroupIso<S, T>`] → [`RingIso<S, T>`] →
/// [`FieldIso<S, T>`]). It introduces a third type parameter `R: Ring` for the
/// scalar ring over which both `S` and `T` are algebras.
///
/// # Laws
///
/// 1. **Round-trip identity** — inherited from `Iso<S, T>`.
/// 2. **Scalar-multiplication preservation** — for any `r: R` and `a: S`,
///    `<Self as Iso<S, T>>::to_target(a.scale(r)) ==
///     <Self as Iso<S, T>>::to_target(a).scale(r)`.
/// 3. **Algebra-product preservation** — for all `a, b: S`,
///    `<Self as Iso<S, T>>::to_target(a * b) ==
///     <Self as Iso<S, T>>::to_target(a) * <Self as Iso<S, T>>::to_target(b)`.
///    Where the algebra product coincides with ring multiplication, this
///    overlaps with `RingIso<S, T>`; in general the two are independent.
///
/// The marker does not require `S: Ring` or `T: Ring`. Implementers that
/// satisfy both ring and algebra structure typically write the marker impls
/// separately. Verified by
/// [`crate::iso::witness::test_support::assert_witness_algebra_iso_law`].
///
/// [`GroupIso<S, T>`]: crate::iso::witness::GroupIso
/// [`RingIso<S, T>`]: crate::iso::witness::RingIso
/// [`FieldIso<S, T>`]: crate::iso::witness::FieldIso
pub trait AlgebraIso<S, T, R>: Iso<S, T>
where
    S: Algebra<R>,
    T: Algebra<R>,
    R: Ring,
{
}
