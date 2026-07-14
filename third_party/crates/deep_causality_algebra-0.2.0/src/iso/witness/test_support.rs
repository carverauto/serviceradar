/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Property-test helpers for the Tier 2 witness-typed isomorphism trait
//! family ([`crate::iso::witness::Iso`] and its marker subtraits).
//!
//! These helpers are exposed as `pub fn` (not `#[cfg(test)]`-gated) so they
//! are reachable from integration tests under `deep_causality_num/tests/`.
//! This follows the codebase convention established by [`crate::utils_tests`]
//! and the Tier 1 equivalents in [`crate::iso::test_support`].
//!
//! Each helper exercises **only** its marker subtrait's own contribution to
//! the homomorphism chain. Inherited laws are not re-checked — consumers
//! verifying a deeper marker should compose with the parent helpers to
//! cover the full chain.
//!
//! - [`assert_witness_iso_round_trip`] — round-trip identity through
//!   `Iso<S, T>::to_target` and `Iso<S, T>::to_source`.
//! - [`assert_witness_group_iso_law`] — additive group homomorphism.
//! - [`assert_witness_ring_iso_laws`] — addition AND multiplication
//!   homomorphism (addition is also inherited from `GroupIso<S, T>` but
//!   re-asserted here because the helper takes the same `(a, b)` pair).
//! - [`assert_witness_field_iso_laws`] — multiplicative inverse preservation
//!   only (the field-specific contribution; ring laws are NOT re-checked).
//! - [`assert_witness_algebra_iso_law`] — scalar multiplication preservation.
//! - [`assert_witness_division_algebra_iso_law`] — conjugation preservation
//!   only (the division-algebra-specific contribution; algebra-product
//!   preservation from `AlgebraIso<S, T, R>` is NOT re-checked).

use crate::iso::witness::algebra_iso::AlgebraIso;
use crate::iso::witness::division_algebra_iso::DivisionAlgebraIso;
use crate::iso::witness::field_iso::FieldIso;
use crate::iso::witness::group_iso::GroupIso;
use crate::iso::witness::iso::Iso;
use crate::iso::witness::ring_iso::RingIso;
use crate::{Algebra, DivisionAlgebra, Field, Group, Ring};

/// Asserts the round-trip identity law for a witness-typed [`Iso<S, T>`] impl
/// in both directions independently.
///
/// Verifies:
/// 1. `to_source(to_target(s)) == s` (S -> T -> S), and
/// 2. `to_target(to_source(t)) == t` (T -> S -> T)
///
/// Both checks are necessary: deriving `t` from `s` would only exercise the
/// subset of `T` reachable via `to_target`, leaving witnesses where
/// `to_source` is many-to-one (i.e. `T` values outside `to_target`'s image
/// collapse to the same `S`) undetected. Callers must supply an independent
/// `t: T` so non-bijective witnesses cannot slip through.
pub fn assert_witness_iso_round_trip<W, S, T>(s: S, t: T)
where
    W: Iso<S, T>,
    S: Clone + PartialEq + core::fmt::Debug,
    T: Clone + PartialEq + core::fmt::Debug,
{
    let t_from_s: T = W::to_target(s.clone());
    let s_back: S = W::to_source(t_from_s);
    assert_eq!(
        s, s_back,
        "Witness iso round-trip S -> T -> S failed: original {:?} differs from to_source(to_target(original))",
        s
    );

    let s_from_t: S = W::to_source(t.clone());
    let t_back: T = W::to_target(s_from_t);
    assert_eq!(
        t, t_back,
        "Witness iso round-trip T -> S -> T failed: original {:?} differs from to_target(to_source(original))",
        t
    );
}

/// Asserts the additive group homomorphism law for a witness-typed
/// [`GroupIso<S, T>`] impl.
pub fn assert_witness_group_iso_law<W, S, T>(a: S, b: S)
where
    W: GroupIso<S, T>,
    S: Group + Clone + PartialEq + core::fmt::Debug,
    T: Group + Clone + PartialEq + core::fmt::Debug,
{
    let lhs: T = W::to_target(a.clone() + b.clone());
    let rhs: T = W::to_target(a) + W::to_target(b);
    assert_eq!(
        lhs, rhs,
        "Witness GroupIso homomorphism failed: to_target(a + b) != to_target(a) + to_target(b)"
    );
}

/// Asserts the ring homomorphism laws for a witness-typed [`RingIso<S, T>`]
/// impl: addition AND multiplication preserved.
pub fn assert_witness_ring_iso_laws<W, S, T>(a: S, b: S)
where
    W: RingIso<S, T>,
    S: Ring + Clone + PartialEq + core::fmt::Debug,
    T: Ring + Clone + PartialEq + core::fmt::Debug,
{
    let lhs_add: T = W::to_target(a.clone() + b.clone());
    let rhs_add: T = W::to_target(a.clone()) + W::to_target(b.clone());
    assert_eq!(
        lhs_add, rhs_add,
        "Witness RingIso addition homomorphism failed: to_target(a + b) != to_target(a) + to_target(b)"
    );

    let lhs_mul: T = W::to_target(a.clone() * b.clone());
    let rhs_mul: T = W::to_target(a) * W::to_target(b);
    assert_eq!(
        lhs_mul, rhs_mul,
        "Witness RingIso multiplication homomorphism failed: to_target(a * b) != to_target(a) * to_target(b)"
    );
}

/// Asserts the **field-specific** homomorphism law for a witness-typed
/// [`FieldIso<S, T>`] impl: multiplicative inverse preservation only.
///
/// `FieldIso<S, T>` extends `RingIso<S, T>` which extends `GroupIso<S, T>`.
/// The ring-level laws (addition and multiplication homomorphism) and the
/// group-level law (round-trip) are **not** re-checked here — by design,
/// each helper exercises only the marker subtrait's own contribution.
/// Consumers verifying a `FieldIso<S, T>` impl should also run
/// [`assert_witness_iso_round_trip`], [`assert_witness_group_iso_law`], and
/// [`assert_witness_ring_iso_laws`] against the same witness to cover the
/// inherited laws.
///
/// Caller is responsible for passing a non-zero `a`.
pub fn assert_witness_field_iso_laws<W, S, T>(a: S)
where
    W: FieldIso<S, T>,
    S: Field + Clone + PartialEq + core::fmt::Debug,
    T: Field + Clone + PartialEq + core::fmt::Debug,
{
    let inv_s: S = a.clone().inverse();
    let from_inv: T = W::to_target(inv_s);
    let inv_from: T = W::to_target(a).inverse();
    assert_eq!(
        from_inv, inv_from,
        "Witness FieldIso multiplicative-inverse homomorphism failed: to_target(a.inverse()) != to_target(a).inverse()"
    );
}

/// Asserts the scalar-multiplication preservation law for a witness-typed
/// [`AlgebraIso<S, T, R>`] impl.
pub fn assert_witness_algebra_iso_law<W, S, T, R>(a: S, r: R)
where
    W: AlgebraIso<S, T, R>,
    R: Ring + Clone,
    S: Algebra<R> + Clone + PartialEq + core::fmt::Debug,
    T: Algebra<R> + Clone + PartialEq + core::fmt::Debug,
{
    let scaled_s: S = a.clone().scale(r.clone());
    let from_scaled: T = W::to_target(scaled_s);
    let scale_from: T = W::to_target(a).scale(r);
    assert_eq!(
        from_scaled, scale_from,
        "Witness AlgebraIso scalar-multiplication homomorphism failed: to_target(a.scale(r)) != to_target(a).scale(r)"
    );
}

/// Asserts the conjugation-preservation law for a witness-typed
/// [`DivisionAlgebraIso<S, T, R>`] impl.
pub fn assert_witness_division_algebra_iso_law<W, S, T, R>(a: S)
where
    W: DivisionAlgebraIso<S, T, R>,
    R: Field + Clone,
    S: DivisionAlgebra<R> + Clone + PartialEq + core::fmt::Debug,
    T: DivisionAlgebra<R> + Clone + PartialEq + core::fmt::Debug,
{
    let conj_s: S = a.clone().conjugate();
    let from_conj: T = W::to_target(conj_s);
    let conj_from: T = W::to_target(a).conjugate();
    assert_eq!(
        from_conj, conj_from,
        "Witness DivisionAlgebraIso conjugation homomorphism failed: to_target(a.conjugate()) != to_target(a).conjugate()"
    );
}
