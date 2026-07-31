/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, NoConstraint};

/// Witness capability: an [`HKT`] functor whose `Type<T>` can be compared structurally
/// whenever the payload `T: PartialEq`.
///
/// This is the `PartialEq` analogue of [`Functor`](crate::Functor): where `Functor` lets a witness
/// supply `fmap`, `EqFunctor` lets a witness supply the structural equality of its container. It is
/// the capability that gives the recursive carriers `Free` and `Cofree` their `PartialEq`/`Eq`
/// instances.
///
/// # Why a capability, not `#[derive]`
///
/// `Free`/`Cofree` store their recursive child under a GAT projection —
/// `Suspend(Self::Type<Box<Free<F, A>>>)`. `#[derive(PartialEq)]`, or any hand impl gated on the
/// projection bound `Self::Type<Box<Free<F, A>>>: PartialEq`, makes the instance *conditional on
/// that projection*, so discharging it at a concrete witness re-enters the trait solver and
/// overflows (`error[E0275]`). Routing the comparison through `eq_type` breaks the cycle: the
/// recursion discharges against the carrier's own `PartialEq` impl and its stable bounds
/// (`F: EqFunctor`, `A: PartialEq`), exactly as a plain recursive `enum List { Nil, Cons(i32,
/// Box<List>) }` does.
///
/// # Opt-in
///
/// A witness opts in by implementing this trait; nothing existing changes and no instance appears
/// for a witness that does not. The crate's built-in single-hole functor witnesses
/// (`OptionWitness`, `VecWitness`, `BoxWitness`, `LinkedListWitness`, `VecDequeWitness`) implement
/// it — the body is the container's own `==`.
///
/// Scoped to `HKT<Constraint = NoConstraint>` because `Free`/`Cofree` require it.
///
/// # Law
///
/// `eq_type` is the container's structural equality: it is reflexive, symmetric, and transitive
/// whenever `T`'s `PartialEq` is. The `PartialEq` it induces on `Free`/`Cofree` is then a structural
/// equivalence by induction on the tree.
///
/// # Examples
///
/// ```rust
/// use deep_causality_haft::{EqFunctor, OptionWitness};
///
/// let a: Option<i32> = Some(5);
/// let b: Option<i32> = Some(5);
/// assert!(OptionWitness::eq_type(&a, &b));
/// ```
///
/// The `PartialEq` on `Free`/`Cofree` is opt-in: a witness that does **not** implement `EqFunctor`
/// gives no `==` for its programs.
///
/// ```compile_fail
/// use deep_causality_haft::{Free, HKT, NoConstraint};
///
/// struct NoEq;
/// impl HKT for NoEq {
///     type Constraint = NoConstraint;
///     type Type<T> = Option<T>;
/// }
///
/// let a: Free<NoEq, i32> = Free::Pure(1);
/// let b: Free<NoEq, i32> = Free::Pure(1);
/// let _ = a == b; // `NoEq: EqFunctor` is not satisfied — does not compile.
/// ```
pub trait EqFunctor: HKT<Constraint = NoConstraint> {
    /// Structural equality of two `Self::Type<T>` containers, given `T: PartialEq`.
    fn eq_type<T: PartialEq>(a: &Self::Type<T>, b: &Self::Type<T>) -> bool;
}
