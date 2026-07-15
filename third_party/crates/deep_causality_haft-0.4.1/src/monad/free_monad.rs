/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # The Free Monad
//!
//! `Free<F, A>` is the **free monad** on a functor `F`: the initial monad through which `F`'s
//! operations factor. It turns any [`Functor`] into a [`Monad`] and is the canonical carrier for
//! **algebraic effects with handlers** (Plotkin & Power, *Algebraic Operations and Generic
//! Effects*, 2003; Swierstra, *Data Types à la Carte*, JFP 18(4), 2008; Awodey, *Category Theory*
//! 2nd ed. §10). An *operation* lives in the functor `F`; a *program* is a tree of operations
//! terminated by pure values; a *handler* is an `F`-algebra that folds the tree into a result.
//!
//! ```text
//! Free f a = Pure a | Suspend (f (Free f a))
//! ```
//!
//! - `pure a`               = `Pure a`
//! - `bind (Pure a) k`      = `k a`
//! - `bind (Suspend s) k`   = `Suspend (fmap (|m| bind m k) s)`
//!
//! The three monad laws hold for **every** functor `F`, using only `F`'s functor laws. This is
//! machine-checked in `lean/DeepCausalityFormal/Haft/FreeMonad.lean` and witnessed in
//! `deep_causality_haft/tests/formalization_lean/free_monad_tests.rs`.
//!
//! ## Rust encoding note (`Fn + Clone`)
//!
//! The monadic operations ([`bind`](Free::bind), [`map`](Free::map)) require the mapping function
//! to be `Fn + Clone`, not the bare `FnMut` of the [`Functor`]/[`Monad`] traits. The reason is
//! ownership: `bind` threads the continuation through **every** hole of the functor node, and a
//! multi-hole functor (e.g. a map/`Vec`) needs one copy of the continuation per hole. This is the
//! standard Rust free-monad constraint, so the monadic surface is provided as inherent methods;
//! [`FreeWitness`] implements [`HKT`] and [`Pure`] (which need no cloning).

use crate::{Functor, HKT, NoConstraint, Pure, Satisfies};
use alloc::boxed::Box;
use core::marker::PhantomData;

/// The free monad on a functor `F`: `Pure a | Suspend (f (Free f a))`.
///
/// `F` is an [`HKT`] witness that is a [`Functor`] over the unconstrained (`NoConstraint`)
/// universe — the functor of *operations*. `Free<F, A>` is a program tree whose leaves are pure
/// `A` values and whose branches are `F`-shaped operation nodes.
pub enum Free<F, A>
where
    F: HKT<Constraint = NoConstraint>,
{
    /// A pure value — the leaf / monadic unit.
    Pure(A),
    /// An operation node: an `F`-structure of sub-programs.
    Suspend(F::Type<Box<Free<F, A>>>),
}

impl<F, A> Free<F, A>
where
    F: HKT<Constraint = NoConstraint> + Functor<F>,
{
    /// The monadic unit: lift a pure value into the free monad. (`Pure a`.)
    #[inline]
    pub fn pure(a: A) -> Self {
        Free::Pure(a)
    }

    /// Lift a single operation `F::Type<A>` into the free monad — one node whose sub-programs are
    /// pure leaves. (`Suspend (fmap Pure fa)`; the generic effect `lift : f ~> Free f`.)
    #[inline]
    pub fn lift(fa: F::Type<A>) -> Self {
        Free::Suspend(F::fmap(fa, |a| Box::new(Free::Pure(a))))
    }

    /// Kleisli bind: sequence a continuation after this program. On a `Pure` leaf the continuation
    /// runs immediately; on a `Suspend` node the bind is pushed functorially under every hole.
    ///
    /// The continuation is `Fn + Clone` because it is threaded through every hole of the node
    /// (see the module-level encoding note).
    pub fn bind<B, K>(self, k: K) -> Free<F, B>
    where
        K: Fn(A) -> Free<F, B> + Clone,
    {
        match self {
            Free::Pure(a) => k(a),
            Free::Suspend(fa) => Free::Suspend(F::fmap(fa, move |boxed: Box<Free<F, A>>| {
                let k_branch = k.clone();
                Box::new((*boxed).bind(k_branch))
            })),
        }
    }

    /// The functor action on the free monad, derived from `bind`/`pure` (`fmap f = bind (pure ∘ f)`).
    pub fn map<B, Fun>(self, f: Fun) -> Free<F, B>
    where
        Fun: Fn(A) -> B + Clone,
    {
        self.bind(move |a| Free::Pure(f(a)))
    }

    /// Interpret (fold / run) the program with a handler: a `pure_case` for leaves and an
    /// `algebra: F::Type<X> -> X` for operation nodes. This is the catamorphism that gives the
    /// operations meaning — the "handler" of the algebraic-effect reading.
    pub fn fold<X, P, Alg>(self, pure_case: &P, algebra: &Alg) -> X
    where
        P: Fn(A) -> X,
        Alg: Fn(F::Type<X>) -> X,
    {
        match self {
            Free::Pure(a) => pure_case(a),
            Free::Suspend(fa) => algebra(F::fmap(fa, |boxed: Box<Free<F, A>>| {
                (*boxed).fold(pure_case, algebra)
            })),
        }
    }
}

// NOTE: `Free` has no *derived* `PartialEq`/`Eq`/`Debug`/`Clone`. `#[derive]`, or any hand impl
// gated on the GAT-projection field bound `F::Type<Box<Free<F,A>>>: Trait`, makes the instance
// conditional on that projection, so discharging it at a concrete witness re-enters the trait
// solver and overflows (`error[E0275]`). Instead, opt-in `PartialEq`/`Eq`/`Debug` are provided in
// `free_instances.rs` for any operation functor whose witness implements `EqFunctor`/`DebugFunctor`
// — the recursion runs through those witness methods, not a projection bound, so it terminates.
// Programs can still be compared by folding them to a canonical value with `fold` (see the witness
// tests); the two agree. (`Clone` is still absent — add a `CloneFunctor` the same way if needed.)

/// The [`HKT`] witness for the free monad over the operation functor `F`.
pub struct FreeWitness<F>(PhantomData<F>);

impl<F> HKT for FreeWitness<F>
where
    F: HKT<Constraint = NoConstraint>,
{
    type Constraint = NoConstraint;
    type Type<T> = Free<F, T>;
}

impl<F> Pure<FreeWitness<F>> for FreeWitness<F>
where
    F: HKT<Constraint = NoConstraint> + Functor<F>,
{
    #[inline]
    fn pure<T>(value: T) -> <FreeWitness<F> as HKT>::Type<T>
    where
        T: Satisfies<NoConstraint>,
    {
        Free::Pure(value)
    }
}
