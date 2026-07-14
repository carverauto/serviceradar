/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A bounded semilattice: a commutative, idempotent monoid.

use crate::{CommutativeMonoid, Idempotent};

/// A **bounded semilattice**: a [`CommutativeMonoid`] that is also [`Idempotent`] — associative,
/// commutative, idempotent, with an identity (the bound).
///
/// The boolean `AggregateLogic` reducers are exactly these: `All` is the bounded ∧-semilattice
/// (identity `true`), `Any` the bounded ∨-semilattice (identity `false`).
pub trait BoundedSemilattice: CommutativeMonoid + Idempotent {}
