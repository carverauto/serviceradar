/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 — natural isomorphism between two arity-5 HKT witnesses
//! ([`HKT5Unbound`]).
//!
//! This is the 5-arity counterpart to [`crate::iso::NaturalIso`], intended
//! for the propagating-effect carrier (per design decision D8 in the
//! `2026-05-20-add-iso-traits` change): the carrier is parametric in
//! `<V, S, C, E, L>` (value, state, context, effect, log) and a Tier 3
//! iso between two such carriers must transport all five parameters.
//!
//! # Laws
//!
//! Mirroring [`crate::iso::NaturalIso`] but lifted to 5 free type
//! parameters: round-trip per parameter tuple, plus naturality in any
//! parameter that the surrounding code maps over.

use crate::{HKT5Unbound, Satisfies};

/// Natural isomorphism between two arity-5 unbound HKT witnesses.
///
/// See the module-level documentation for the laws this trait promises.
pub trait NaturalIso5<F, G>
where
    F: HKT5Unbound,
    G: HKT5Unbound,
{
    /// Maps `F::Type<V, S, C, E, L>` to `G::Type<V, S, C, E, L>`.
    fn to_target<V, S, C, E, L>(fa: F::Type<V, S, C, E, L>) -> G::Type<V, S, C, E, L>
    where
        V: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        S: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        E: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        L: Satisfies<F::Constraint> + Satisfies<G::Constraint>;

    /// Reverse of [`to_target`](Self::to_target).
    fn to_source<V, S, C, E, L>(ga: G::Type<V, S, C, E, L>) -> F::Type<V, S, C, E, L>
    where
        V: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        S: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        E: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        L: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}
