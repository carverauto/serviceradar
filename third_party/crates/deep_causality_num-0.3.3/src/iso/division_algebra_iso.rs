/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::iso::algebra_iso::AlgebraIso;
use crate::{DivisionAlgebra, Field};

/// Marker trait asserting that a bidirectional `From` conversion between `Self`
/// and `T` is a division-algebra homomorphism over a shared scalar field `R`.
///
/// `DivisionAlgebraIso<T, R>` extends [`AlgebraIso<T, R>`] and adds the
/// conjugation and inverse laws specific to division algebras.
///
/// # Laws
///
/// 1. **Algebra homomorphism** — inherited from `AlgebraIso<T, R>` (round-trip,
///    scalar multiplication, algebra-product preservation).
/// 2. **Conjugation preservation** — `T::from(a.conjugate()) == T::from(a).conjugate()`
///    for all `a: Self`.
/// 3. **Inverse preservation** — `T::from(a.inverse()) == T::from(a).inverse()`
///    for all non-zero `a: Self`. Follows from the conjugation and norm-square
///    laws via `a.inverse() == a.conjugate() / a.norm_sqr()`, but is included
///    in the marker promise for explicit downstream-bound checks.
///
/// The where-clause promotes `R` to `Field` (not just `Ring`) — the
/// [`DivisionAlgebra`] trait already requires `R: Field`, so this is just
/// surfacing that constraint at the iso level.
///
/// # Applies to
///
/// - `Complex<F>` ↔ `2×2` real-matrix representation (commutative, associative).
/// - `Quaternion<F>` ↔ Cl(3,0) rotor (associative, non-commutative).
/// - `Octonion<F>` ↔ candidate non-associative correspondence.
///
/// Verified by [`crate::iso::test_support::assert_division_algebra_iso_from_law`].
pub trait DivisionAlgebraIso<T, R>: AlgebraIso<T, R>
where
    Self: DivisionAlgebra<R> + From<T>,
    T: DivisionAlgebra<R> + From<Self>,
    R: Field,
{
}
