/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A commutative monoid: a [`Monoid`](crate::Monoid) whose `combine` is order-independent.

use crate::{Commutative, Monoid};

/// A **commutative monoid**: a [`Monoid`] whose operation additionally satisfies
///
/// - **Commutativity:** `x.combine(y) == y.combine(x)`.
///
/// The [`Commutative`] supertrait carries that promise as a bound, so generic code that needs
/// order-independence can demand it in the type system.
///
/// This is the algebra a `Collection` folds through when child order carries no meaning — the
/// multiset / order-independence property (see `algebraic-causaloid-assumptions.md` #1) follows
/// from commutativity + associativity, not from an ad-hoc assumption.
pub trait CommutativeMonoid: Monoid + Commutative {}
