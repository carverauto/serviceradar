/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Property-test helpers for the Tier 1 isomorphism marker subtraits.
//!
//! These helpers are exposed as `pub fn` (not `#[cfg(test)]`-gated) so they
//! are reachable from integration tests under `deep_causality_num/tests/`.
//! This follows the codebase convention established by
//! [`crate::utils_tests`] — Bazel cannot access files in `tests/` from `src/`,
//! so coverage-counting test utilities must live in the `src` tree.
//!
//! Each helper exercises **only** its marker subtrait's own contribution to
//! the homomorphism chain. Inherited laws are not re-checked — consumers
//! verifying a deeper marker (e.g. `FieldIso<T>`) should compose with the
//! parent helpers to cover the full chain.
//!
//! - [`assert_iso_from_round_trip`] — bidirectional `From` round-trip identity.
//! - [`assert_group_iso_from_law`] — additive group homomorphism (`+`).
//! - [`assert_ring_iso_from_laws`] — addition AND multiplication homomorphism
//!   (the ring-specific contribution: multiplication; addition is inherited
//!   from `GroupIso<T>` and re-asserted here for completeness because the
//!   helper takes the same `(a, b)` pair).
//! - [`assert_field_iso_from_laws`] — multiplicative inverse preservation only
//!   (the field-specific contribution; ring laws are NOT re-checked).
//! - [`assert_algebra_iso_from_law`] — scalar multiplication preservation.
//! - [`assert_division_algebra_iso_from_law`] — conjugation preservation only
//!   (the division-algebra-specific contribution; algebra-product preservation
//!   from `AlgebraIso<T, R>` is NOT re-checked).
//!
//! The helpers take owned values (caller provides representative inputs) and
//! use `assert_eq!` with descriptive failure messages. No randomized input
//! generation; callers wrap calls in their own randomized iteration when
//! exhaustive coverage is wanted.

use crate::{Algebra, DivisionAlgebra, Field, Group, Ring};

/// Asserts that bidirectional `From<S>` / `From<T>` impls round-trip cleanly
/// in both directions.
///
/// Verifies the Tier 1 base law: any `From` pair participating in a Tier 1
/// marker subtrait must satisfy `S::from(T::from(s)) == s` and
/// `T::from(S::from(t)) == t`.
///
/// Both checks are exercised against independent inputs: deriving `t` from
/// `s` would only cover the subset of `T` reachable via `T::from`, leaving
/// pairs where `S::from` is many-to-one (i.e. `T` values outside `T::from`'s
/// image collapse to the same `S`) undetected.
pub fn assert_iso_from_round_trip<S, T>(s: S, t: T)
where
    S: From<T> + Clone + PartialEq + core::fmt::Debug,
    T: From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let t_from_s: T = T::from(s.clone());
    let s_back: S = S::from(t_from_s);
    assert_eq!(
        s, s_back,
        "From round-trip S -> T -> S failed: original {:?} differs from S::from(T::from(original))",
        s
    );

    let s_from_t: S = S::from(t.clone());
    let t_back: T = T::from(s_from_t);
    assert_eq!(
        t, t_back,
        "From round-trip T -> S -> T failed: original {:?} differs from T::from(S::from(original))",
        t
    );
}

/// Asserts the additive group homomorphism law for a [`crate::iso::GroupIso<T>`]
/// impl: `T::from(a + b) == T::from(a) + T::from(b)`.
///
/// In this crate `Group: AddGroup`, so the group operation is `+`. The helper
/// is therefore an additive-group homomorphism check.
pub fn assert_group_iso_from_law<S, T>(a: S, b: S)
where
    S: Group + From<T> + Clone + PartialEq + core::fmt::Debug,
    T: Group + From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let lhs: T = T::from(a.clone() + b.clone());
    let rhs: T = T::from(a) + T::from(b);
    assert_eq!(
        lhs, rhs,
        "GroupIso homomorphism failed: T::from(a + b) != T::from(a) + T::from(b)"
    );
}

/// Asserts the ring homomorphism laws for a [`crate::iso::RingIso<T>`] impl:
/// addition AND multiplication preserved.
///
/// 1. `T::from(a + b) == T::from(a) + T::from(b)` (additive homomorphism).
/// 2. `T::from(a * b) == T::from(a) * T::from(b)` (multiplicative homomorphism).
pub fn assert_ring_iso_from_laws<S, T>(a: S, b: S)
where
    S: Ring + From<T> + Clone + PartialEq + core::fmt::Debug,
    T: Ring + From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let lhs_add: T = T::from(a.clone() + b.clone());
    let rhs_add: T = T::from(a.clone()) + T::from(b.clone());
    assert_eq!(
        lhs_add, rhs_add,
        "RingIso addition homomorphism failed: T::from(a + b) != T::from(a) + T::from(b)"
    );

    let lhs_mul: T = T::from(a.clone() * b.clone());
    let rhs_mul: T = T::from(a) * T::from(b);
    assert_eq!(
        lhs_mul, rhs_mul,
        "RingIso multiplication homomorphism failed: T::from(a * b) != T::from(a) * T::from(b)"
    );
}

/// Asserts the **field-specific** homomorphism law for a
/// [`crate::iso::FieldIso<T>`] impl: multiplicative inverse preservation.
///
/// `FieldIso<T>` extends `RingIso<T>` which extends `GroupIso<T>`. The
/// ring-level laws (addition and multiplication homomorphism) and the
/// group-level law (round-trip) are **not** re-checked here — by design,
/// each helper exercises only the marker subtrait's own contribution.
/// Consumers verifying a `FieldIso<T>` impl should therefore also run
/// [`assert_iso_from_round_trip`], [`assert_group_iso_from_law`], and
/// [`assert_ring_iso_from_laws`] against the same type pair to cover the
/// inherited laws.
///
/// Caller is responsible for passing a non-zero `a`. For `a == 0`, the inverse
/// is undefined / returns Infinity per IEEE 754 for floating-point fields, and
/// the check would be vacuous or misleading.
pub fn assert_field_iso_from_laws<S, T>(a: S)
where
    S: Field + From<T> + Clone + PartialEq + core::fmt::Debug,
    T: Field + From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let inv_s: S = a.clone().inverse();
    let from_inv: T = T::from(inv_s);
    let inv_from: T = T::from(a).inverse();
    assert_eq!(
        from_inv, inv_from,
        "FieldIso multiplicative-inverse homomorphism failed: T::from(a.inverse()) != T::from(a).inverse()"
    );
}

/// Asserts the algebra homomorphism law for a [`crate::iso::AlgebraIso<T, R>`]
/// impl: scalar multiplication is preserved.
///
/// `T::from(a.scale(r)) == T::from(a).scale(r)` for any scalar `r: R` and
/// vector `a: Self`.
pub fn assert_algebra_iso_from_law<S, T, R>(a: S, r: R)
where
    R: Ring + Clone,
    S: Algebra<R> + From<T> + Clone + PartialEq + core::fmt::Debug,
    T: Algebra<R> + From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let scaled_s: S = a.clone().scale(r.clone());
    let from_scaled: T = T::from(scaled_s);
    let scale_from: T = T::from(a).scale(r);
    assert_eq!(
        from_scaled, scale_from,
        "AlgebraIso scalar-multiplication homomorphism failed: T::from(a.scale(r)) != T::from(a).scale(r)"
    );
}

/// Asserts the division algebra homomorphism law for a
/// [`crate::iso::DivisionAlgebraIso<T, R>`] impl: conjugation is preserved.
///
/// `T::from(a.conjugate()) == T::from(a).conjugate()` for all `a: Self`.
///
/// The companion inverse law (`T::from(a.inverse()) == T::from(a).inverse()`)
/// follows mathematically from conjugation preservation plus norm-square
/// preservation, but is not directly tested here; for division algebras over
/// floating-point fields, the inverse check is best deferred to a tolerance-
/// aware comparison rather than `assert_eq!`.
pub fn assert_division_algebra_iso_from_law<S, T, R>(a: S)
where
    R: Field + Clone,
    S: DivisionAlgebra<R> + From<T> + Clone + PartialEq + core::fmt::Debug,
    T: DivisionAlgebra<R> + From<S> + Clone + PartialEq + core::fmt::Debug,
{
    let conj_s: S = a.clone().conjugate();
    let from_conj: T = T::from(conj_s);
    let conj_from: T = T::from(a).conjugate();
    assert_eq!(
        from_conj, conj_from,
        "DivisionAlgebraIso conjugation homomorphism failed: T::from(a.conjugate()) != T::from(a).conjugate()"
    );
}
