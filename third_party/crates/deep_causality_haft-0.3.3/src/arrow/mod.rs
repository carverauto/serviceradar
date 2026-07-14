/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The value-level `Arrow` algebra: a strong category for wiring operators together.
//!
//! Where [`Morphism`](crate::Morphism) is the *witness-level* interface (identity +
//! application, but no composition under the no-`dyn` policy), this module provides the
//! *value-level* algebra where composition is **total**: every combinator returns a new
//! concrete `Arrow`-implementing type, so composites compose.
//!
//! - **Category:** [`Id`], [`Lift`] (lift a function), [`Compose`] (`f >>> g`).
//! - **Strength (the monoidal product):** [`First`], [`Second`], [`Split`] (`***`),
//!   [`Fanout`] (`&&&`) — the operation the causal monad's `bind` cannot express.
//! - **Builder:** [`arrow`] + [`ArrowBuilder`] hide the combinator types behind a fluent
//!   chain (the textual form of a wiring diagram).
//!
//! # Intellectual lineage
//!
//! This design is the convergence of several lineages put together. In chronological order:
//!
//! - **1972 — Defunctionalization.** John C. Reynolds, *"Definitional Interpreters for
//!   Higher-Order Programming Languages,"* Proc. ACM Annual Conference (1972; reprinted in
//!   Higher-Order and Symbolic Computation 11(4), 1998). Represent higher-order / closure
//!   values as first-order data so they can be named and composed without indirection —
//!   why each combinator here is a concrete generic struct rather than a `Box<dyn Fn>`.
//! - **1986 — Typestate.** Robert E. Strom & Shaula Yemini, *"Typestate: A Programming
//!   Concept for Enhancing Software Reliability,"* IEEE Transactions on Software
//!   Engineering SE-12(1). Encode an object's state in its type — what lets
//!   [`ArrowBuilder`] thread the growing arrow type through `Self`, hidden from the caller.
//! - **1991 — String diagrams.** André Joyal & Ross Street, *"The Geometry of Tensor
//!   Calculus, I,"* Advances in Mathematics 88(1). The graphical calculus of monoidal
//!   categories: a fluent chain is the textual form of a wiring diagram.
//! - **1997 — Freyd / premonoidal categories.** John Power & Edmund Robinson,
//!   *"Premonoidal categories and notions of computation,"* Mathematical Structures in
//!   Computer Science 7(5). The categorical home of arrows; *strength* is the name for
//!   [`First`] / [`Split`].
//! - **2000 — Arrows.** John Hughes, *"Generalising Monads to Arrows,"* Science of
//!   Computer Programming 37(1–3). The Arrow abstraction and its combinators — `arr`,
//!   `>>>`, `first`, `***`, `&&&` — which appear here as [`Lift`], [`Compose`], [`First`] /
//!   [`Second`], [`Split`], [`Fanout`].
//! - **2001 — Arrow notation.** Ross Paterson, *"A New Notation for Arrows,"* ICFP 2001.
//!   The `proc` surface syntax over arrow combinators — the ancestor of the
//!   builder-as-syntax idea ([`arrow`] / [`ArrowBuilder`]).
//! - **2009 — Finally tagless.** Jacques Carette, Oleg Kiselyov & Chung-chieh Shan,
//!   *"Finally Tagless, Partially Evaluated,"* Journal of Functional Programming 19(5)
//!   (earlier APLAS 2007). Encode a typed DSL's terms as trait methods so each term is a
//!   value whose type is built up — no GADT/AST — exactly the combinators-as-generic-
//!   structs encoding used here. (Related: Oliveira & Cook, *"Extensibility for the
//!   Masses: Practical Extensibility with Object Algebras,"* ECOOP 2012.)
//! - **Rust `std::iter::Iterator` (the canonical embodiment).** `Map<I, F>`,
//!   `Filter<I, P>`, `Zip<A, B>` are generic adapter structs, and `xs.map(f).filter(p)`
//!   builds a monomorphized nested type the caller never names. That is precisely the
//!   "builder hides the combinator types" property — realized here for the *full* Arrow
//!   (sequential `>>>` **and** the monoidal product `***` / `&&&`), not just `map`/`filter`.
//!   `Future` combinators and `tower::Service` + `Layer` are the same encoding.
//!
//! The synthesis specific to this crate: apply the `Iterator`-adapter encoding to the
//! *complete* strong category and use the fluent builder as the camouflage layer for the
//! Causal Arrow generalization — a well-typed fluent chain *is* a string diagram. See
//! `openspec/notes/arrow/causal-arrow-generalization.md` §8 and
//! `openspec/notes/arrow/causal-process-builder.md`.

mod arrow_endo;
mod builder;
mod compose;
mod fanout;
mod first;
mod id;
mod lift;
mod second;
mod split;

pub use arrow_endo::EndoArrow;
pub use builder::{ArrowBuilder, arrow};
pub use compose::Compose;
pub use fanout::Fanout;
pub use first::First;
pub use id::Id;
pub use lift::Lift;
pub use second::Second;
pub use split::Split;

/// A value-level arrow `In → Out`: a runnable, composable transformation.
///
/// # Category Theory
///
/// `Arrow` is a **strong category** (Hughes' Arrow): `Id`/`Compose` give the category,
/// the `first`/`split` combinators give the monoidal **strength**, and `fanout` gives the
/// diagonal. Unlike the witness-level [`Morphism`](crate::Morphism) — which cannot host
/// composition, because composing two closures yields an unnameable type and `Box<dyn Fn>`
/// is forbidden — every combinator here returns a *new concrete type*, so **composition is
/// total** and everything is monomorphized (zero-cost, no `dyn`, no macros).
///
/// The combinator methods are provided; an implementor supplies only `In`, `Out`, and
/// `run`. `run` takes `&self`, so an arrow is reusable.
#[diagnostic::on_unimplemented(
    message = "`{Self}` is not an `Arrow`",
    note = "lift a function with `Lift::new(f)` (or the `arrow(f)` builder), or implement `Arrow` for your operator type"
)]
pub trait Arrow {
    /// The input object the arrow consumes.
    type In;
    /// The output object the arrow produces.
    type Out;

    /// Apply the arrow to an input.
    fn run(&self, input: Self::In) -> Self::Out;

    /// Sequential composition `f >>> g`: run `self`, then `g` on its output.
    #[inline]
    fn compose<G>(self, g: G) -> Compose<Self, G>
    where
        Self: Sized,
        G: Arrow<In = Self::Out>,
    {
        Compose::new(self, g)
    }

    /// `first`: lift `A → B` to `(A, C) → (B, C)`, passing the second component through.
    #[inline]
    fn first<C>(self) -> First<Self, C>
    where
        Self: Sized,
    {
        First::new(self)
    }

    /// `second`: lift `A → B` to `(C, A) → (C, B)`, passing the first component through.
    #[inline]
    fn second<C>(self) -> Second<Self, C>
    where
        Self: Sized,
    {
        Second::new(self)
    }

    /// The monoidal product `***`: run `self` and `g` in parallel on a pair —
    /// `(A, C) → (B, D)` from `self: A → B` and `g: C → D`.
    #[inline]
    fn split<G>(self, g: G) -> Split<Self, G>
    where
        Self: Sized,
        G: Arrow,
    {
        Split::new(self, g)
    }

    /// Fanout `&&&`: feed one input to two arrows — `A → (B, C)` from `self: A → B` and
    /// `g: A → C`. Requires `In: Clone`.
    #[inline]
    fn fanout<G>(self, g: G) -> Fanout<Self, G>
    where
        Self: Sized,
        G: Arrow<In = Self::In>,
        Self::In: Clone,
    {
        Fanout::new(self, g)
    }
}
