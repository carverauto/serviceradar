/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::arrow::{Arrow, Compose, Fanout, Lift, Split};

/// Return type of [`ArrowBuilder::then_fn`], factored out to satisfy
/// `clippy::type_complexity`.
type ThenFn<S, C, G> = ArrowBuilder<Compose<S, Lift<<S as Arrow>::Out, C, G>>>;

/// A fluent builder over the [`Arrow`] algebra that hides the combinator types.
///
/// The builder threads the growing arrow type through `Self` exactly like the CDL
/// typestate builder threads its witness — the types are real but **camouflaged**, so a
/// user writes a left-to-right chain and never names `Compose`/`Split`/`Lift` or the
/// witness-level [`Morphism`](crate::Morphism). It is the textual form of a wiring diagram.
///
/// Start a chain with [`arrow`] (lifting a function) or [`ArrowBuilder::new`] (wrapping an
/// existing arrow); end it with [`build`](ArrowBuilder::build) (yield the composed arrow)
/// or [`run`](ArrowBuilder::run) (apply it).
///
/// ```
/// use deep_causality_haft::arrow;
///
/// let pipeline = arrow(|x: i32| x + 1).then_fn(|x| x * 2).build();
/// // (no Compose/Lift/Morphism named anywhere)
/// use deep_causality_haft::Arrow;
/// assert_eq!(pipeline.run(3), 8);
/// ```
pub struct ArrowBuilder<S>(S);

/// Starts an arrow chain by lifting a function `F: Fn(A) -> B` into a builder.
#[inline]
pub fn arrow<A, B, F>(f: F) -> ArrowBuilder<Lift<A, B, F>>
where
    F: Fn(A) -> B,
{
    ArrowBuilder(Lift::new(f))
}

impl<S> ArrowBuilder<S>
where
    S: Arrow,
{
    /// Wraps an existing arrow in a builder.
    #[inline]
    pub const fn new(arrow: S) -> Self {
        ArrowBuilder(arrow)
    }

    /// Sequential step: compose with another arrow (`then` is an alias of `compose`).
    #[inline]
    pub fn then<G>(self, g: G) -> ArrowBuilder<Compose<S, G>>
    where
        G: Arrow<In = S::Out>,
    {
        ArrowBuilder(self.0.compose(g))
    }

    /// Sequential step lifting a raw closure (so the user need not write `Lift::new`).
    #[inline]
    pub fn then_fn<C, G>(self, g: G) -> ThenFn<S, C, G>
    where
        G: Fn(S::Out) -> C,
    {
        ArrowBuilder(self.0.compose(Lift::new(g)))
    }

    /// Parallel-product step (`par` is an alias of `split` / `***`).
    #[inline]
    pub fn par<G>(self, g: G) -> ArrowBuilder<Split<S, G>>
    where
        G: Arrow,
    {
        ArrowBuilder(self.0.split(g))
    }

    /// Fanout step (`&&&`): feed the same input to a second arrow.
    #[inline]
    pub fn fanout<G>(self, g: G) -> ArrowBuilder<Fanout<S, G>>
    where
        G: Arrow<In = S::In>,
        S::In: Clone,
    {
        ArrowBuilder(self.0.fanout(g))
    }

    /// Terminal: yield the composed [`Arrow`] value (reusable, further composable).
    #[inline]
    pub fn build(self) -> S {
        self.0
    }

    /// Terminal: apply the composed arrow to an input.
    #[inline]
    pub fn run(&self, input: S::In) -> S::Out {
        self.0.run(input)
    }
}
