/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Property-test helpers for the Tier 3 natural-iso trait family.
//!
//! These helpers are exposed as `pub fn` (not `#[cfg(test)]`-gated) so they
//! are reachable from integration tests under `deep_causality_haft/tests/`.
//! This follows the convention already established by
//! `crate::utils_tests` and the Tier 1 / Tier 2 equivalents in
//! `deep_causality_num` (Bazel cannot see `tests/` from `src/`, so
//! coverage-counting test utilities must live in `src/`).
//!
//! - [`assert_natural_iso_round_trip`] — bidirectional round-trip identity.
//!   Takes independent `fa: F::Type<T>` and `ga: G::Type<T>` inputs so that
//!   non-bijective natural transformations cannot slip through (same
//!   design rationale as the Tier 1 / Tier 2 round-trip helpers).
//! - [`assert_natural_iso_naturality`] — naturality with respect to `fmap`:
//!   `to_target(F::fmap(fa, h)) == G::fmap(to_target(fa), h)`.

use crate::{Functor, HKT, NaturalIso, Satisfies};

/// Asserts the round-trip identity law for a Tier 3
/// [`NaturalIso<F, G>`] impl in both directions independently.
///
/// Verifies:
/// 1. `to_source(to_target(fa)) == fa` for the supplied `fa: F::Type<T>`.
/// 2. `to_target(to_source(ga)) == ga` for the supplied `ga: G::Type<T>`.
///
/// Both checks are necessary. If `ga` were derived from `fa` via
/// `to_target`, the reverse check would only exercise the subset of
/// `G::Type<T>` reachable through the forward map; a `to_source` that
/// collapses distinct `G` values to the same `F` (i.e. is not injective)
/// would pass undetected. Callers supply an independent `ga` so such
/// witnesses cannot slip through.
pub fn assert_natural_iso_round_trip<W, F, G, T>(fa: F::Type<T>, ga: G::Type<T>)
where
    W: NaturalIso<F, G>,
    F: HKT,
    G: HKT,
    T: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
    F::Type<T>: Clone + PartialEq + core::fmt::Debug,
    G::Type<T>: Clone + PartialEq + core::fmt::Debug,
{
    let g_from_f: G::Type<T> = W::to_target(fa.clone());
    let fa_back: F::Type<T> = W::to_source(g_from_f);
    assert_eq!(
        fa, fa_back,
        "NaturalIso round-trip F -> G -> F failed: original {:?} differs from to_source(to_target(original))",
        fa
    );

    let f_from_g: F::Type<T> = W::to_source(ga.clone());
    let ga_back: G::Type<T> = W::to_target(f_from_g);
    assert_eq!(
        ga, ga_back,
        "NaturalIso round-trip G -> F -> G failed: original {:?} differs from to_target(to_source(original))",
        ga
    );
}

/// Asserts the naturality law for a Tier 3 [`NaturalIso<F, G>`] impl:
/// the iso commutes with `fmap` from both witnesses' [`Functor`] impls.
///
/// Verifies `to_target(F::fmap(fa, h)) == G::fmap(to_target(fa), h)` for
/// the supplied input `fa` and function `h`. The symmetric law via
/// `to_source` is implied by the forward naturality together with the
/// round-trip law; callers exercising deep coverage should compose with
/// [`assert_natural_iso_round_trip`].
pub fn assert_natural_iso_naturality<W, F, G, A, B, Func>(fa: F::Type<A>, h: Func)
where
    W: NaturalIso<F, G>,
    F: HKT + Functor<F>,
    G: HKT + Functor<G>,
    A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
    B: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
    F::Type<A>: Clone,
    G::Type<B>: PartialEq + core::fmt::Debug,
    Func: FnMut(A) -> B + Clone,
{
    let lhs: G::Type<B> = W::to_target(<F as Functor<F>>::fmap(fa.clone(), h.clone()));
    let rhs: G::Type<B> = <G as Functor<G>>::fmap(W::to_target(fa), h);
    assert_eq!(
        lhs, rhs,
        "NaturalIso naturality failed: to_target(F::fmap(fa, h)) != G::fmap(to_target(fa), h)"
    );
}
