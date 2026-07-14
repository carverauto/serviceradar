/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `Disjunction(bool)` — the boolean `∨` bounded semilattice (the `AggregateLogic::Any` carrier).

use crate::{BoundedSemilattice, Commutative, CommutativeMonoid, Idempotent, Monoid};

/// The boolean disjunction (`∨`) monoid: identity `false`, `combine = ||`. A bounded semilattice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Disjunction(pub bool);

impl Monoid for Disjunction {
    #[inline]
    fn empty() -> Self {
        Disjunction(false)
    }
    #[inline]
    fn combine(self, other: Self) -> Self {
        Disjunction(self.0 || other.0)
    }
}
// `a ∨ b = b ∨ a` — the marker `CommutativeMonoid` requires.
impl Commutative for Disjunction {}
impl CommutativeMonoid for Disjunction {}
impl Idempotent for Disjunction {}
impl BoundedSemilattice for Disjunction {}
