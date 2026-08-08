/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Tier 3 — natural isomorphism between two arity-2 unbound HKT witnesses
//! ([`HKT2Unbound`]).
//!
//! Mirrors [`crate::iso::NaturalIso`] lifted to two free type parameters
//! (e.g. `(A, B)` tuples, `Either<A, B>`, `Result<A, B>`-shaped carriers).

use crate::{HKT2Unbound, Satisfies};

/// Natural isomorphism between two arity-2 unbound HKT witnesses.
pub trait NaturalIso2<F, G>
where
    F: HKT2Unbound,
    G: HKT2Unbound,
{
    /// Maps `F::Type<A, B>` to `G::Type<A, B>`.
    fn to_target<A, B>(fa: F::Type<A, B>) -> G::Type<A, B>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>;

    /// Reverse of [`to_target`](Self::to_target).
    fn to_source<A, B>(ga: G::Type<A, B>) -> F::Type<A, B>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>,
        B: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}
