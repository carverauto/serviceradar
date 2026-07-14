/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 — natural isomorphism between two arity-4 unbound HKT witnesses
//! ([`HKT4Unbound`]).
//!
//! Mirrors [`crate::iso::NaturalIso`] lifted to four free type parameters
//! (e.g. `(A, B, C, D)` tuples, `RiemannTensor<A, B, C, D>`-shaped carriers).

use crate::{HKT4Unbound, Satisfies};

/// Natural isomorphism between two arity-4 unbound HKT witnesses.
pub trait NaturalIso4<F, G>
where
    F: HKT4Unbound,
    G: HKT4Unbound,
{
    /// Maps `F::Type<A, B, C, D>` to `G::Type<A, B, C, D>`.
    fn to_target<A, B, C, D>(fa: F::Type<A, B, C, D>) -> G::Type<A, B, C, D>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        D: Satisfies<F::Constraint> + Satisfies<G::Constraint>;

    /// Reverse of [`to_target`](Self::to_target).
    fn to_source<A, B, C, D>(ga: G::Type<A, B, C, D>) -> F::Type<A, B, C, D>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        C: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        D: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}
