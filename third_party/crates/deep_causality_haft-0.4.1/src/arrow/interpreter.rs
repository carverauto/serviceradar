/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # The one-way interpreter — `ArrowTerm → Kleisli<M>`
//!
//! [`ArrowCore::interpret`](crate::ArrowCore::interpret) runs a reified term in the *function*
//! category (pure `ArrowVal → ArrowVal`). This module lands the same term in the **Kleisli
//! category** of an effect monad `M`: [`ArrowCore::interpret_kleisli`] extends an interpretation of
//! the generators into Kleisli arrows `V → M<V>` homomorphically over the whole term, so a wiring
//! diagram becomes an effectful pipeline `ArrowVal<V> → M<ArrowVal<V>>`.
//!
//! It is a **functor** from the free arrow to [`Kleisli<M>`](crate::Kleisli): `Id` maps to the
//! Kleisli identity ([`pure`](crate::Pure::pure)) and `Compose` maps to Kleisli composition
//! ([`bind`](crate::Monad::bind)) — `preserves_id` and `preserves_compose`. The map is *one-way*:
//! syntax (the storable [`ArrowCore`](crate::ArrowCore)) is interpreted into semantics
//! ([`Kleisli<M>`](crate::Kleisli)), never the reverse. The strength combinators sequence the monad
//! over the two halves of a [`ArrowVal::Pair`](crate::ArrowVal): `Split`/`First`/`Second`
//! independently, `Fanout` after copying the input.
//!
//! Naturality — a monad morphism `M ⇒ N` commuting with the interpretation — is the
//! [`NaturalTransformation`](crate::NaturalTransformation) square, proved separately. The three
//! facts are machine-checked in `lean/DeepCausalityFormal/Haft/Interpreter.lean`
//! (`haft.interpreter.{preserves_id, preserves_compose, naturality}`) and witnessed in
//! `deep_causality_haft/tests/formalization_lean/interpreter_tests.rs`.

use crate::arrow::arrow_term::{ArrowCore, ArrowVal};
use crate::{Functor, HKT, Monad, NoConstraint, Pure};
use alloc::boxed::Box;

impl<G> ArrowCore<G> {
    /// Interprets the term into the Kleisli category of the monad `M`: the effectful extension of a
    /// generator interpretation `phi: G → (V → M<V>)`.
    ///
    /// This is the unique arrow-homomorphism `ArrowTerm → Kleisli<M>` determined by `phi`
    /// (`haft.interpreter.free`-style universal property, inherited from
    /// [`interpret`](ArrowCore::interpret)). `Id` becomes [`pure`](crate::Pure::pure) — the Kleisli
    /// identity — and `Compose` becomes [`bind`](crate::Monad::bind) — Kleisli composition — so the
    /// map preserves identity and composition. The strength combinators thread `M` over the two
    /// halves of a [`ArrowVal::Pair`].
    ///
    /// `M` is scoped to the unconstrained (`NoConstraint`) universe, matching
    /// [`Kleisli<M>`](crate::Kleisli); `V: Clone` supports the copying `Fanout` and the
    /// `FnMut`-captured pass-through halves of `First`/`Second`/`Split`.
    pub fn interpret_kleisli<M, V, Phi>(
        &self,
        phi: &Phi,
        input: ArrowVal<V>,
    ) -> M::Type<ArrowVal<V>>
    where
        M: Monad<M> + HKT<Constraint = NoConstraint>,
        Phi: Fn(&G, V) -> M::Type<V>,
        V: Clone,
    {
        match self {
            // Id ↦ Kleisli identity (pure).
            ArrowCore::Id => <M as Pure<M>>::pure(input),
            // A generator acts on a leaf via `phi`, its result rewrapped as a leaf; a mis-shaped
            // (pair) input passes through purely.
            ArrowCore::Gen(g) => match input {
                ArrowVal::Leaf(v) => <M as Functor<M>>::fmap(phi(g, v), ArrowVal::Leaf),
                other => <M as Pure<M>>::pure(other),
            },
            // Compose ↦ Kleisli composition (bind): run `f`, then `h` on its (effectful) output.
            ArrowCore::Compose(f, h) => {
                <M as Monad<M>>::bind(f.interpret_kleisli::<M, V, Phi>(phi, input), move |mid| {
                    h.interpret_kleisli::<M, V, Phi>(phi, mid)
                })
            }
            ArrowCore::First(f) => match input {
                ArrowVal::Pair(a, b) => {
                    <M as Monad<M>>::bind(f.interpret_kleisli::<M, V, Phi>(phi, *a), move |a2| {
                        <M as Pure<M>>::pure(ArrowVal::Pair(Box::new(a2), b.clone()))
                    })
                }
                other => <M as Pure<M>>::pure(other),
            },
            ArrowCore::Second(h) => match input {
                ArrowVal::Pair(a, b) => {
                    <M as Monad<M>>::bind(h.interpret_kleisli::<M, V, Phi>(phi, *b), move |b2| {
                        <M as Pure<M>>::pure(ArrowVal::Pair(a.clone(), Box::new(b2)))
                    })
                }
                other => <M as Pure<M>>::pure(other),
            },
            ArrowCore::Split(f, h) => match input {
                ArrowVal::Pair(a, b) => {
                    let b = *b;
                    <M as Monad<M>>::bind(f.interpret_kleisli::<M, V, Phi>(phi, *a), move |a2| {
                        <M as Monad<M>>::bind(
                            h.interpret_kleisli::<M, V, Phi>(phi, b.clone()),
                            move |b2| {
                                <M as Pure<M>>::pure(ArrowVal::Pair(
                                    Box::new(a2.clone()),
                                    Box::new(b2),
                                ))
                            },
                        )
                    })
                }
                other => <M as Pure<M>>::pure(other),
            },
            ArrowCore::Fanout(f, h) => {
                let copy = input.clone();
                <M as Monad<M>>::bind(f.interpret_kleisli::<M, V, Phi>(phi, input), move |a2| {
                    <M as Monad<M>>::bind(
                        h.interpret_kleisli::<M, V, Phi>(phi, copy.clone()),
                        move |b2| {
                            <M as Pure<M>>::pure(ArrowVal::Pair(Box::new(a2.clone()), Box::new(b2)))
                        },
                    )
                })
            }
            // The choice fragment (⊕): route on the sum node — the effect runs only on the taken
            // branch (a sum routes, it never copies, so no `Clone` of the payload is needed).
            ArrowCore::Left(f) => match input {
                ArrowVal::InL(a) => <M as Functor<M>>::fmap(
                    f.interpret_kleisli::<M, V, Phi>(phi, *a),
                    ArrowVal::inl,
                ),
                other @ (ArrowVal::Leaf(_) | ArrowVal::Pair(..) | ArrowVal::InR(_)) => {
                    <M as Pure<M>>::pure(other)
                }
            },
            ArrowCore::Right(h) => match input {
                ArrowVal::InR(b) => <M as Functor<M>>::fmap(
                    h.interpret_kleisli::<M, V, Phi>(phi, *b),
                    ArrowVal::inr,
                ),
                other @ (ArrowVal::Leaf(_) | ArrowVal::Pair(..) | ArrowVal::InL(_)) => {
                    <M as Pure<M>>::pure(other)
                }
            },
            ArrowCore::Choice(f, h) => match input {
                ArrowVal::InL(a) => <M as Functor<M>>::fmap(
                    f.interpret_kleisli::<M, V, Phi>(phi, *a),
                    ArrowVal::inl,
                ),
                ArrowVal::InR(b) => <M as Functor<M>>::fmap(
                    h.interpret_kleisli::<M, V, Phi>(phi, *b),
                    ArrowVal::inr,
                ),
                other @ (ArrowVal::Leaf(_) | ArrowVal::Pair(..)) => <M as Pure<M>>::pure(other),
            },
            // Fanin eliminates the sum: the taken branch's effectful result IS the output — no
            // re-injection (the coproduct elimination, `haft.either.coproduct_universal`).
            ArrowCore::Fanin(f, h) => match input {
                ArrowVal::InL(a) => f.interpret_kleisli::<M, V, Phi>(phi, *a),
                ArrowVal::InR(b) => h.interpret_kleisli::<M, V, Phi>(phi, *b),
                other @ (ArrowVal::Leaf(_) | ArrowVal::Pair(..)) => <M as Pure<M>>::pure(other),
            },
        }
    }
}
