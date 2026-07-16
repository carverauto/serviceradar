/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalFlow;
use core::marker::PhantomData;
use deep_causality_haft::Arrow;

/// Phantom marker carrying `CausalLift`'s type parameters with the right variance (contravariant in
/// the inputs `A` / `S` / `C`, covariant in the outputs `B` / `S` / `C`).
type LiftMarker<A, B, S, C> = PhantomData<fn(A, S, Option<C>) -> (B, S, C)>;

/// Lifts a stage function `(A, S, Option<C>) -> CausalFlow<B, S, C>` into a reusable causal arrow.
///
/// This is the leaf carrier of the Causal Arrow engine: the Kleisli analogue of
/// [`deep_causality_haft::Lift`]. A stage **receives** the incoming `(value, state, context)` — so
/// composition threads state exactly as the causal monad's `bind` does (`s0 → s1 → s2`) — and the
/// stateless case is a specialization: a stage written `|a, _, _| …` simply ignores the state. It
/// implements [`Arrow`] with `In = (A, S, Option<C>)` and `Out = CausalFlow<B, S, C>`, so a lifted
/// stage is a first-class, reusable arrow value whose `run` takes `&self`.
pub struct CausalLift<A, B, S, C, F> {
    f: F,
    _marker: LiftMarker<A, B, S, C>,
}

impl<A, B, S, C, F> CausalLift<A, B, S, C, F>
where
    F: Fn(A, S, Option<C>) -> CausalFlow<B, S, C>,
{
    /// Wraps a stage function into a causal arrow.
    #[inline]
    pub const fn new(f: F) -> Self {
        Self {
            f,
            _marker: PhantomData,
        }
    }
}

impl<A, B, S, C, F> Arrow for CausalLift<A, B, S, C, F>
where
    F: Fn(A, S, Option<C>) -> CausalFlow<B, S, C>,
{
    type In = (A, S, Option<C>);
    type Out = CausalFlow<B, S, C>;

    #[inline]
    fn run(&self, input: (A, S, Option<C>)) -> CausalFlow<B, S, C> {
        let (a, s, c) = input;
        (self.f)(a, s, c)
    }
}
