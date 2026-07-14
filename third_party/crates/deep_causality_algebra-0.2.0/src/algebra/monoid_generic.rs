/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! A carrier-and-operation-generic monoid, decoupled from `Zero`/`One` and the arithmetic
//! operators.
//!
//! The numeric monoids in this crate (`AddMonoid`, `MulMonoid`) bake the operation into `Add`/`Mul`
//! and the identity into `Zero`/`One`, so a type that has neither — `bool` under `∧`, a verdict
//! carrier, an aggregation reducer — cannot be a monoid through them. `Monoid` is the generic
//! structure: an identity constructor and an associative binary combine, with no arithmetic bound.
//! It is the algebra the `Collection` causaloid folds its children through
//! (see `openspec/notes/causal-algebra/algebraic-causaloid.md`, gap A1).

/// A **monoid**: a set with an associative binary operation `combine` and an identity `empty`.
///
/// # Laws (the implementor upholds)
/// 1. **Left identity:** `Self::empty().combine(x) == x`.
/// 2. **Right identity:** `x.combine(Self::empty()) == x`.
/// 3. **Associativity:** `x.combine(y).combine(z) == x.combine(y.combine(z))`.
///
/// Unlike [`AddMonoid`](crate::AddMonoid)/[`MulMonoid`](crate::MulMonoid) this requires no `Add`,
/// `Mul`, `Zero`, or `One` — the operation and identity are the trait's own methods.
pub trait Monoid: Sized {
    /// The identity element: `empty().combine(x) == x == x.combine(empty())`.
    fn empty() -> Self;

    /// The associative binary operation.
    fn combine(self, other: Self) -> Self;
}
