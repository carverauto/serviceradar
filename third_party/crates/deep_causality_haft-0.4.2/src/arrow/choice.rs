/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The choice fragment `⊕` (ArrowChoice): routing over the coproduct [`Either`].
//!
//! Where `first`/`split`/`fanout` are the **product** (`⊗`) fragment of the strong category, the
//! combinators here are the **coproduct** (`⊕`) fragment — Hughes' `ArrowChoice` (John Hughes,
//! "Generalising Monads to Arrows," *Sci. Comput. Program.* 37(1–3), 2000, §5): [`Left`],
//! [`Right`], [`Choice`] (`+++`), and [`Fanin`] (`|||`), each a defunctionalized generic struct
//! over [`Either`] (no `dyn`, no `unsafe`, no macros), built on the proven coproduct universal
//! property (`haft.either.coproduct_universal`).
//!
//! Two independent requirements force this generator (the roadmap's Stage 2b):
//! - **Quantum faithfulness.** Sequential + tensor composition alone cannot make all no-influence
//!   relations of a unitary simultaneously evident; causally faithful decomposition requires
//!   **direct-sum** structure (R. Lorenz & J. Barrett, "Causal and compositional structure of
//!   unitary transformations," *Quantum* 5, 511 (2021), §3–4 — the extended circuit diagrams).
//!   `deep_causality_quantum` instantiates `⊕` as the Hilbert-space direct sum.
//! - **Classical case-splitting.** Contextual switches, regime selection, and counterfactual
//!   branching are coproduct eliminations; `Fanin` is exactly that elimination.
//!
//! Laws (`left (arr f) = arr (f ⊕ id)`, composition/exchange, `fanin` as the coproduct
//! elimination, and the `⊗`-over-`⊕` distributivity equations used) are machine-checked in
//! `lean/DeepCausalityFormal/Haft/ArrowChoice.lean` (`haft.arrow_choice.laws`) and witnessed in
//! `deep_causality_haft/tests/formalization_lean/arrow_choice_tests.rs`.

use crate::Either;
use crate::arrow::Arrow;
use core::marker::PhantomData;

/// `left`: lift `F: A → B` to `Either<A, C> → Either<B, C>`, acting on the left summand and
/// passing a `Right` value through unchanged.
pub struct Left<F, C>(F, PhantomData<C>);

impl<F, C> Left<F, C> {
    /// Builds the `left` arrow. Prefer [`Arrow::left`].
    #[inline]
    pub const fn new(f: F) -> Self {
        Left(f, PhantomData)
    }
}

impl<F, C> Arrow for Left<F, C>
where
    F: Arrow,
{
    type In = Either<F::In, C>;
    type Out = Either<F::Out, C>;

    #[inline]
    fn run(&self, input: Either<F::In, C>) -> Either<F::Out, C> {
        match input {
            Either::Left(a) => Either::Left(self.0.run(a)),
            Either::Right(c) => Either::Right(c),
        }
    }
}

/// `right`: lift `F: A → B` to `Either<C, A> → Either<C, B>`, acting on the right summand and
/// passing a `Left` value through unchanged.
pub struct Right<F, C>(F, PhantomData<C>);

impl<F, C> Right<F, C> {
    /// Builds the `right` arrow. Prefer [`Arrow::right`].
    #[inline]
    pub const fn new(f: F) -> Self {
        Right(f, PhantomData)
    }
}

impl<F, C> Arrow for Right<F, C>
where
    F: Arrow,
{
    type In = Either<C, F::In>;
    type Out = Either<C, F::Out>;

    #[inline]
    fn run(&self, input: Either<C, F::In>) -> Either<C, F::Out> {
        match input {
            Either::Left(c) => Either::Left(c),
            Either::Right(a) => Either::Right(self.0.run(a)),
        }
    }
}

/// The coproduct sum `+++`: route each summand to its own arrow —
/// `Either<A, C> → Either<B, D>` from `F: A → B` and `G: C → D`.
pub struct Choice<F, G>(F, G);

impl<F, G> Choice<F, G> {
    /// Builds the `+++` arrow. Prefer [`Arrow::choice`].
    #[inline]
    pub const fn new(f: F, g: G) -> Self {
        Choice(f, g)
    }
}

impl<F, G> Arrow for Choice<F, G>
where
    F: Arrow,
    G: Arrow,
{
    type In = Either<F::In, G::In>;
    type Out = Either<F::Out, G::Out>;

    #[inline]
    fn run(&self, input: Either<F::In, G::In>) -> Either<F::Out, G::Out> {
        match input {
            Either::Left(a) => Either::Left(self.0.run(a)),
            Either::Right(c) => Either::Right(self.1.run(c)),
        }
    }
}

/// Fanin `|||`: the coproduct **elimination** — both branches converge on one output type,
/// `Either<A, C> → B` from `F: A → B` and `G: C → B`. This is the universal map of the coproduct
/// (`haft.either.coproduct_universal`) as an arrow.
pub struct Fanin<F, G>(F, G);

impl<F, G> Fanin<F, G> {
    /// Builds the `|||` arrow. Prefer [`Arrow::fanin`].
    #[inline]
    pub const fn new(f: F, g: G) -> Self {
        Fanin(f, g)
    }
}

impl<F, G> Arrow for Fanin<F, G>
where
    F: Arrow,
    G: Arrow<Out = F::Out>,
{
    type In = Either<F::In, G::In>;
    type Out = F::Out;

    #[inline]
    fn run(&self, input: Either<F::In, G::In>) -> F::Out {
        match input {
            Either::Left(a) => self.0.run(a),
            Either::Right(c) => self.1.run(c),
        }
    }
}
