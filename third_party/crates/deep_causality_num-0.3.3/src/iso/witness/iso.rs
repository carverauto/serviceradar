/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

/// Witness-typed isomorphism between two types `S` (source) and `T` (target).
///
/// `Iso<S, T>` is **Tier 2** of the isomorphism trait family in
/// `deep_causality_num`. Unlike Tier 1 — which rides on top of std's
/// `From`/`Into` for in-crate isos — Tier 2 carries its own conversion methods
/// and is implementable on any type (the source `S`, the target `T`, or a
/// dedicated witness type). The implementer choice is determined by the
/// orphan rule and the surrounding crate-dependency graph.
///
/// # Method naming: `to_target` / `to_source`
///
/// Method names are deliberately `to_target` (source → target) and `to_source`
/// (target → source) rather than `forward` / `backward` or `from` / `into`.
/// Two reasons:
///
/// 1. **`forward` / `backward` collides with the EPP framework's temporal
///    vocabulary.** Higher-level crates (`deep_causality_core`,
///    `deep_causality_haft`) use "forward in time" throughout the propagating-
///    effect machinery. A method called `forward(eff)` on a `PropagatingEffect`
///    iso would be misread as "advance one step in time" rather than "convert
///    type representation." `to_target` / `to_source` carries no temporal
///    connotation and encodes the direction in the method name itself.
///
/// 2. **`from` / `into` would conflict with std `From`/`Into` semantics.**
///    `From::from(x)` constructs `Self` from `x`; on a witness type, the
///    witness is not the target — so reusing `from` as a method name would
///    suggest an operation the trait doesn't perform.
///
/// # Laws
///
/// 1. **Round-trip identity** —
///    `<Self as Iso<S, T>>::to_source(<Self as Iso<S, T>>::to_target(s)) == s`
///    for all `s: S`, and the symmetric law for `T`. Verified by property
///    tests in [`crate::iso::witness::test_support::assert_witness_iso_round_trip`].
///
/// 2. **No structure preserved at this level.** `Iso<S, T>` alone does not
///    promise any algebraic-structure preservation. Use [`GroupIso<S, T>`],
///    [`RingIso<S, T>`], [`FieldIso<S, T>`], [`AlgebraIso<S, T, R>`], or
///    [`DivisionAlgebraIso<S, T, R>`] to add those guarantees.
///
/// # Implementer placement
///
/// For a single-convention iso between two types `S` and `T`:
///
/// - If both types are in the same crate or the orphan rule allows
///   bidirectional `From`, **prefer Tier 1** (`From`/`Into` plus marker
///   subtraits like [`crate::iso::GroupIso<T>`]).
/// - If bidirectional `From` is blocked by the orphan rule (typical for
///   cross-crate isos with one-way dependencies), use Tier 2 with the impl on
///   whichever of `S` or `T` is local to the crate writing the impl.
///
/// Dedicated zero-sized witness types (separate from `S` and `T`) are
/// structurally available but currently unused — they would be reserved for
/// a future multi-convention scenario where multiple iso conventions between
/// the same `(S, T)` pair need to coexist.
///
/// [`GroupIso<S, T>`]: crate::iso::witness::GroupIso
/// [`RingIso<S, T>`]: crate::iso::witness::RingIso
/// [`FieldIso<S, T>`]: crate::iso::witness::FieldIso
/// [`AlgebraIso<S, T, R>`]: crate::iso::witness::AlgebraIso
/// [`DivisionAlgebraIso<S, T, R>`]: crate::iso::witness::DivisionAlgebraIso
pub trait Iso<S, T> {
    /// Converts a value of type `S` into a value of type `T`.
    fn to_target(s: S) -> T;

    /// Converts a value of type `T` back into a value of type `S`.
    fn to_source(t: T) -> S;
}
