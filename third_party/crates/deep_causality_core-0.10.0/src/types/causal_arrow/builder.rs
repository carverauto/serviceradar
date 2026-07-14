/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalFlow;
use crate::types::causal_arrow::{CausalFlowOut, CausalLift, KleisliCompose};
use deep_causality_haft::Arrow;

/// Return type of [`CausalArrowBuilder::next`], factored out to keep the signature legible.
type Next<P, NV, G> = CausalArrowBuilder<
    KleisliCompose<
        P,
        CausalLift<
            <<P as Arrow>::Out as CausalFlowOut>::Value,
            NV,
            <<P as Arrow>::Out as CausalFlowOut>::State,
            <<P as Arrow>::Out as CausalFlowOut>::Context,
            G,
        >,
    >,
>;

/// Starts a causal-arrow chain by lifting a stage function `A -> CausalFlow<B, S, C>`.
///
/// This is the entry point of the *engine* layer. The routine surface for composing pipelines is the
/// `CausalFlow` DSL (`next`); reach for the engine only when a composite must be held as a reusable
/// value (stored, passed, or run on many inputs).
#[inline]
pub fn causal_arrow<A, B, S, C, F>(f: F) -> CausalArrowBuilder<CausalLift<A, B, S, C, F>>
where
    F: Fn(A) -> CausalFlow<B, S, C>,
{
    CausalArrowBuilder(CausalLift::new(f))
}

/// A fluent builder over the Causal Arrow engine that hides the nested combinator types.
///
/// `next` composes the next sub-process (Kleisli composition); `build` yields the composed arrow as
/// a reusable value; `run` applies it.
pub struct CausalArrowBuilder<P>(P);

impl<P> CausalArrowBuilder<P>
where
    P: Arrow,
    P::Out: CausalFlowOut,
{
    /// Compose the next sub-process: a stage `g: Value -> CausalFlow<NV>` over the current arrow's
    /// output value, Kleisli-composed onto the chain.
    #[inline]
    pub fn next<G, NV>(self, g: G) -> Next<P, NV, G>
    where
        G: Fn(
            <P::Out as CausalFlowOut>::Value,
        ) -> CausalFlow<
            NV,
            <P::Out as CausalFlowOut>::State,
            <P::Out as CausalFlowOut>::Context,
        >,
    {
        CausalArrowBuilder(KleisliCompose::new(self.0, CausalLift::new(g)))
    }

    /// Yield the composed arrow as a reusable, further-composable value.
    #[inline]
    pub fn build(self) -> P {
        self.0
    }

    /// Apply the composed arrow to an input.
    #[inline]
    pub fn run(&self, input: P::In) -> P::Out {
        self.0.run(input)
    }
}
