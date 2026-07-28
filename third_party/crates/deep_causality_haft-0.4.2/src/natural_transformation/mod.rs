/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Natural transformations between HKT functors.
//!
//! A [`NaturalTransformation`] `F ⇒ G` is a family of maps `transform: F<A> → G<A>`, one per object
//! `A`, that commutes with mapping — the **naturality square**
//! `transform ∘ fmap f = fmap f ∘ transform`. It is the morphism between functors, and the shape a
//! monad morphism takes when it relates the targets of two Kleisli
//! [interpreters](crate::ArrowCore::interpret_kleisli): transporting an interpretation along
//! `F ⇒ G` commutes with the interpreter exactly when this square holds.
//!
//! The law is a *property* of the component (Rust cannot enforce it in the trait); it is checked for
//! [`OptionToVec`] in `deep_causality_haft/tests/formalization_lean/interpreter_tests.rs` and proved
//! in `lean/DeepCausalityFormal/Haft/Interpreter.lean` (`haft.interpreter.naturality`).

use crate::{HKT, Satisfies};

/// A natural transformation `F ⇒ G` between two [`HKT`] functors.
///
/// The single component [`transform`](NaturalTransformation::transform) maps `F<A>` to `G<A>`
/// uniformly in `A`. Lawful instances additionally satisfy naturality:
/// `transform(fmap(fa, f)) == fmap(transform(fa), f)` for every `f`.
pub trait NaturalTransformation<F, G>
where
    F: HKT,
    G: HKT,
{
    /// The component at `A`: reshape an `F`-structure into a `G`-structure without touching payload.
    fn transform<A>(fa: F::Type<A>) -> G::Type<A>
    where
        A: Satisfies<F::Constraint> + Satisfies<G::Constraint>;
}

/// The natural transformation `Option ⇒ Vec`: `None ↦ []`, `Some a ↦ [a]`.
///
/// A canonical lawful component — the "at most one element" embedding — used to witness
/// `haft.interpreter.naturality`.
#[cfg(feature = "alloc")]
pub struct OptionToVec;

#[cfg(feature = "alloc")]
impl NaturalTransformation<crate::OptionWitness, crate::VecWitness> for OptionToVec {
    #[inline]
    fn transform<A>(
        fa: <crate::OptionWitness as HKT>::Type<A>,
    ) -> <crate::VecWitness as HKT>::Type<A>
    where
        A: Satisfies<crate::NoConstraint>,
    {
        match fa {
            Some(a) => alloc::vec![a],
            None => alloc::vec::Vec::new(),
        }
    }
}
