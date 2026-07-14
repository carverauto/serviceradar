/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Field;
use crate::iso::witness::ring_iso::RingIso;

/// Marker trait asserting that an `Iso<S, T>` preserves field structure on
/// the type pair `(S, T)` — addition, multiplication, and multiplicative
/// inverses for non-zero elements.
///
/// `FieldIso<S, T>` extends [`RingIso<S, T>`] and adds the multiplicative-
/// inverse preservation law. The where-clauses promote `S` and `T` to `Field`.
///
/// # Laws
///
/// 1. **Ring homomorphism** — inherited from `RingIso<S, T>`.
/// 2. **Multiplicative inverse preservation** — for every non-zero `a: S`,
///    `<Self as Iso<S, T>>::to_target(a.inverse()) ==
///     <Self as Iso<S, T>>::to_target(a).inverse()`.
///
/// Verified by [`crate::iso::witness::test_support::assert_witness_field_iso_laws`].
///
/// # When this marker does not apply
///
/// Non-commutative algebraic structures (quaternions, Cl(3,0) rotors) are
/// `DivisionAlgebra<R>` but **not** `Field`. The trait bound `T: Field` rules
/// `FieldIso<S, T>` out at the type level for those cases; the correct marker
/// is [`crate::iso::witness::DivisionAlgebraIso<S, T, R>`].
pub trait FieldIso<S, T>: RingIso<S, T>
where
    S: Field,
    T: Field,
{
}
