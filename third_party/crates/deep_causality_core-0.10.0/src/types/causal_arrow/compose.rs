/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalFlow;
use crate::types::causal_arrow::CausalFlowOut;
use deep_causality_haft::Arrow;

/// Kleisli sequential composition of two causal arrows.
///
/// Composing `P: A -> CausalFlow<B>` with `Q: B -> CausalFlow<C>` yields `A -> CausalFlow<C>` by
/// binding `P`'s result into `Q`. This is the Kleisli analogue of [`deep_causality_haft::Compose`]:
/// where the pure combinator applies (`g.run(f.run(x))`), this one binds, so the error, state,
/// context, and log channels thread through and a `P` error short-circuits `Q`.
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
    <P::Out as CausalFlowOut>::State: Clone,
    <P::Out as CausalFlowOut>::Context: Clone,
    Q: Arrow<In = <P::Out as CausalFlowOut>::Value>,
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
        mid.and_then(|v| self.q.run(v).into_causal_flow())
    }
}
