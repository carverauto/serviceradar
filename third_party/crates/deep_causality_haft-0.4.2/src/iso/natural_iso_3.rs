/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 — natural isomorphism between two arity-3 unbound HKT witnesses
//! ([`HKT3Unbound`]).
//!
//! Mirrors [`crate::iso::NaturalIso`] lifted to three free type parameters
//! (e.g. `(A, B, C)` tuples, parametric-state carriers).

use crate::{HKT3Unbound, Satisfies};

/// Natural isomorphism between two arity-3 unbound HKT witnesses.
pub trait NaturalIso3<F, G>
where
    F: HKT3Unbound,
    G: HKT3Unbound,
{
    /// Maps `F::Type<A, B, C>` to `G::Type<A, B, C>`.
    fn to_target<A, B, C>(fa: F::Type<A, B, C>) -> G::Type<A, B, C>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>;

    /// Reverse of [`to_target`](Self::to_target).
    fn to_source<A, B, C>(ga: G::Type<A, B, C>) -> F::Type<A, B, C>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}
