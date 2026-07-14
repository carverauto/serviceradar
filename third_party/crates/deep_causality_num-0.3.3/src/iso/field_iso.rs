/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::Field;
use crate::iso::ring_iso::RingIso;

/// Marker trait asserting that a bidirectional `From` conversion between `Self`
/// and `T` is a field homomorphism — i.e. preserves addition, multiplication,
/// **and** multiplicative inverses for non-zero elements.
///
/// `FieldIso<T>` extends [`RingIso<T>`] and adds the multiplicative-inverse
/// law:
///
/// 1. **Ring homomorphism** — inherited from `RingIso<T>` (addition and
///    multiplication preserved).
/// 2. **Multiplicative inverse** — for every non-zero `a: Self`,
///    `T::from(a.inverse()) == T::from(a).inverse()`. The marker promises this
///    holds modulo floating-point representation; verified by property tests in
///    [`crate::iso::test_support::assert_field_iso_from_laws`].
///
/// The where-clauses promote `Self` and `T` to `Field`. The trait body is
/// empty.
///
/// # When this marker does not apply
///
/// Non-commutative algebraic structures (e.g. quaternions, Cl(3,0) rotors) are
/// `DivisionAlgebra<R>` but **not** `Field`. They satisfy the bidirectional
/// `From` and the multiplicative inverse law in their own algebraic structure,
/// but the where-clause `T: Field` rules this trait out. The correct marker
/// for those cases is [`crate::iso::DivisionAlgebraIso<T, R>`].
pub trait FieldIso<T>: RingIso<T>
where
    Self: Field + From<T>,
    T: Field + From<Self>,
{
}
