/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! `Conjunction(bool)` — the boolean `∧` bounded semilattice (the `AggregateLogic::All` carrier).

use crate::{BoundedSemilattice, Commutative, CommutativeMonoid, Idempotent, Monoid};

/// The boolean conjunction (`∧`) monoid: identity `true`, `combine = &&`. A bounded semilattice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Conjunction(pub bool);

impl Monoid for Conjunction {
    #[inline]
    fn empty() -> Self {
        Conjunction(true)
    }
    #[inline]
    fn combine(self, other: Self) -> Self {
        Conjunction(self.0 && other.0)
    }
}
// `a ∧ b = b ∧ a` — the marker `CommutativeMonoid` requires.
impl Commutative for Conjunction {}
impl CommutativeMonoid for Conjunction {}
impl Idempotent for Conjunction {}
impl BoundedSemilattice for Conjunction {}
