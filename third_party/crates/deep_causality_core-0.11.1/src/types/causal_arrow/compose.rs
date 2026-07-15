/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalFlow;
use crate::types::causal_arrow::CausalFlowOut;
use deep_causality_haft::Arrow;

/// Kleisli sequential composition of two causal arrows.
///
/// Composing `P: (A, S, Option<C>) -> CausalFlow<B, S, C>` with
/// `Q: (B, S, Option<C>) -> CausalFlow<D, S, C>` yields `(A, S, Option<C>) -> CausalFlow<D, S, C>`
/// by binding `P`'s result into `Q`. This is the Kleisli analogue of
/// [`deep_causality_haft::Compose`]: where the pure combinator applies (`g.run(f.run(x))`), this one
/// binds via [`CausalFlow::and_then`], so `P`'s evolved `(state, context)` are threaded into `Q`,
/// the log channel accumulates, and a `P` error short-circuits `Q` (left zero).
pub struct KleisliCompose<P, Q> {
    p: P,
    q: Q,
}

impl<P, Q> KleisliCompose<P, Q> {
    /// Composes `p` followed by `q`.
    #[inline]
    pub const fn new(p: P, q: Q) -> Self {
        Self { p, q }
    }
}

impl<P, Q> Arrow for KleisliCompose<P, Q>
where
    P: Arrow,
    P::Out: CausalFlowOut,
    Q: Arrow<
        In = (
            <P::Out as CausalFlowOut>::Value,
            <P::Out as CausalFlowOut>::State,
            Option<<P::Out as CausalFlowOut>::Context>,
        ),
    >,
    Q::Out: CausalFlowOut<
            State = <P::Out as CausalFlowOut>::State,
            Context = <P::Out as CausalFlowOut>::Context,
        >,
{
    type In = P::In;
    type Out = CausalFlow<
        <Q::Out as CausalFlowOut>::Value,
        <P::Out as CausalFlowOut>::State,
        <P::Out as CausalFlowOut>::Context,
    >;

    #[inline]
    fn run(&self, input: P::In) -> Self::Out {
        let mid = self.p.run(input).into_causal_flow();
        // Thread `P`'s evolved `(value, state, context)` into `Q`.
        mid.and_then(|v, s, c| self.q.run((v, s, c)).into_causal_flow())
    }
}
