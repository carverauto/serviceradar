/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 — natural isomorphism between two arity-1 HKT witnesses.
//!
//! [`NaturalIso<F, G>`] models a *natural isomorphism* `F::Type<T> <-> G::Type<T>`
//! that holds for every `T` and commutes with `fmap`. It is the HKT-level
//! analogue of the Tier 2 witness-typed [`crate::iso`]-equivalent in
//! `deep_causality_num`, lifted to type constructors.
//!
//! # Why not `From`/`Into` here?
//!
//! Tier 1 in `deep_causality_num` builds on `From`/`Into` because the iso
//! relates two concrete types. At Tier 3 the iso relates two *type
//! constructors* — `HKT` witnesses are zero-sized marker types with no
//! values, so `From`/`Into` cannot express a transformation between them.
//! A separate witness-typed trait is required.
//!
//! # Laws
//!
//! Implementers must satisfy, for every type `T` that satisfies both
//! constraints `F::Constraint` and `G::Constraint`, and for every function
//! `h: T -> U`:
//!
//! 1. **Round-trip identity (per `T`)**:
//!    - `to_source(to_target(fa)) == fa` for all `fa: F::Type<T>`
//!    - `to_target(to_source(ga)) == ga` for all `ga: G::Type<T>`
//! 2. **Naturality**: `to_target(F::fmap(fa, h)) == G::fmap(to_target(fa), h)`
//!    (and the symmetric law via `to_source`).
//!
//! The two round-trip laws are tested independently by
//! [`crate::iso::test_support::assert_natural_iso_round_trip`]; naturality
//! is tested by [`crate::iso::test_support::assert_natural_iso_naturality`].

use crate::{HKT, Satisfies};

/// Natural isomorphism between two arity-1 HKT witnesses `F` and `G`.
///
/// See the module-level documentation for the laws this trait promises.
pub trait NaturalIso<F, G>
where
    F: HKT,
    G: HKT,
{
    /// Maps `F::Type<T>` to `G::Type<T>` while preserving structure.
    fn to_target<T>(fa: F::Type<T>) -> G::Type<T>
    where
        T: Satisfies<F::Constraint> + Satisfies<G::Constraint>;

    /// Reverse of [`to_target`](Self::to_target).
    fn to_source<T>(ga: G::Type<T>) -> F::Type<T>
    where
        T: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}
