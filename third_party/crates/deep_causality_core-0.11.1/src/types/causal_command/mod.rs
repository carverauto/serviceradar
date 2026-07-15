/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # `CausalCommand`: the control operation functor
//!
//! `CausalCommand<K>` is the **operation functor** `f` of the adaptive-reasoning free monad
//! (`deep_causality_haft::Free`): the reasoning program is [`CausalEffect<V>`](crate::CausalEffect) =
//! `Free<CausalCommandWitness, Option<V>>` — `Pure(Option<V>)` value/none leaves and
//! `Suspend(CausalCommand<Box<Free<…>>>)` control branches — and the graph-reasoning engine is the
//! `fold` handler that interprets it (Plotkin & Power 2003; Swierstra 2008).
//!
//! `K` is the **sub-program hole**: `RelayTo(target, k)` directs the engine to jump to the causaloid
//! at `target`, feeding it the sub-program `k`. Keeping this control operation out of the value
//! channel (`Option<V>`) is what makes the value functor lawful and the reasoning BFS an honest
//! `Free::fold`.

mod hkt;

/// The control operation functor `f` of the adaptive-reasoning free monad.
///
/// A single operation: `RelayTo(target, sub_program)`. `K` is the sub-program hole (the recursive
/// `Free` position when wrapped as `Free<CausalCommandWitness, _>`).
#[derive(Debug, Clone, PartialEq)]
pub enum CausalCommand<K> {
    /// Jump to the causaloid at index `usize`, feeding it the sub-program `K` as input.
    RelayTo(usize, K),
}

/// The [`HKT`](deep_causality_haft::HKT) witness for [`CausalCommand`] — the operation functor over
/// the unconstrained universe, so it can be the functor of `deep_causality_haft::Free`.
pub struct CausalCommandWitness;
