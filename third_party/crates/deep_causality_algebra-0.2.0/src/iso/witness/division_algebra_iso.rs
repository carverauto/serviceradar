/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::iso::witness::algebra_iso::AlgebraIso;
use crate::{DivisionAlgebra, Field};

/// Marker trait asserting that an `Iso<S, T>` preserves division-algebra
/// structure on the type pair `(S, T, R)` — scalar multiplication, algebra
/// product, conjugation, and inverse.
///
/// `DivisionAlgebraIso<S, T, R>` extends [`AlgebraIso<S, T, R>`] and adds the
/// conjugation-preservation law specific to division algebras. The where-clause
/// promotes `R` to `Field` (not just `Ring`) — `DivisionAlgebra<R>` already
/// requires `R: Field`, so this just surfaces that constraint.
///
/// # Laws
///
/// 1. **Algebra homomorphism** — inherited from `AlgebraIso<S, T, R>`.
/// 2. **Conjugation preservation** — for all `a: S`,
///    `<Self as Iso<S, T>>::to_target(a.conjugate()) ==
///     <Self as Iso<S, T>>::to_target(a).conjugate()`.
/// 3. **Inverse preservation** — for all non-zero `a: S`,
///    `<Self as Iso<S, T>>::to_target(a.inverse()) ==
///     <Self as Iso<S, T>>::to_target(a).inverse()`.
///    Follows from conjugation and norm-square preservation via
///    `a.inverse() == a.conjugate() / a.norm_sqr()`, but included in the
///    marker promise for explicit downstream bound checks.
///
/// # Applies to
///
/// - `Complex<F>` ↔ `2×2` real-matrix representation (commutative, associative).
/// - `Quaternion<F>` ↔ Cl(3,0) rotor (associative, non-commutative).
/// - `Octonion<F>` ↔ a candidate non-associative correspondence.
///
/// Verified by
/// [`crate::iso::witness::test_support::assert_witness_division_algebra_iso_law`].
///
/// [`AlgebraIso<S, T, R>`]: crate::iso::witness::AlgebraIso
pub trait DivisionAlgebraIso<S, T, R>: AlgebraIso<S, T, R>
where
    S: DivisionAlgebra<R>,
    T: DivisionAlgebra<R>,
    R: Field,
{
}
