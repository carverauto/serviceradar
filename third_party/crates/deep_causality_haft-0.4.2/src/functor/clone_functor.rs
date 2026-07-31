/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, NoConstraint};

/// Witness capability: an [`HKT`] functor whose `Type<T>` can be cloned whenever the payload
/// `T: Clone`.
///
/// This is the [`Clone`] analogue of [`Functor`](crate::Functor) and the twin of
/// [`EqFunctor`](crate::EqFunctor) / [`DebugFunctor`](crate::DebugFunctor): the witness supplies the
/// structural clone of its container, which gives the recursive carriers `Free` and `Cofree` their
/// `Clone` instances without the trait-solver overflow a `#[derive]` (or a `Self::Type<..>: Clone`
/// field bound) hits on the GAT projection `Self::Type<Box<Free<F, A>>>` (see
/// [`EqFunctor`](crate::EqFunctor) for the mechanism).
///
/// # Opt-in
///
/// A witness opts in by implementing this trait; nothing existing changes and no instance appears
/// for a witness that does not. The crate's built-in single-hole functor witnesses
/// (`OptionWitness`, `VecWitness`, `BoxWitness`, `LinkedListWitness`, `VecDequeWitness`) implement it
/// — the body delegates to the container's own `Clone`.
///
/// Scoped to `HKT<Constraint = NoConstraint>` because `Free`/`Cofree` require it.
///
/// # Law
///
/// `clone_type` is the container's structural clone: the returned container is equal to the input
/// (`clone_type(fa) == fa` whenever the witness is also an [`EqFunctor`](crate::EqFunctor)) and
/// preserves its `F`-shape.
/// The `Clone` it induces on `Free`/`Cofree` is then a structural copy by induction on the tree.
///
/// # Examples
///
/// ```rust
/// use deep_causality_haft::{CloneFunctor, OptionWitness};
///
/// let a: Option<i32> = Some(5);
/// let b = OptionWitness::clone_type(&a);
/// assert_eq!(a, b);
/// ```
///
/// The `Clone` on `Free`/`Cofree` is opt-in: a witness that does **not** implement `CloneFunctor`
/// gives no `Clone` for its programs.
///
/// ```compile_fail
/// use deep_causality_haft::{Free, HKT, NoConstraint};
///
/// struct NoClone;
/// impl HKT for NoClone {
///     type Constraint = NoConstraint;
///     type Type<T> = Option<T>;
/// }
///
/// let a: Free<NoClone, i32> = Free::Pure(1);
/// let _ = a.clone(); // `NoClone: CloneFunctor` is not satisfied — does not compile.
/// ```
pub trait CloneFunctor: HKT<Constraint = NoConstraint> {
    /// Structurally clone a `Self::Type<T>` container, given `T: Clone`.
    fn clone_type<T: Clone>(fa: &Self::Type<T>) -> Self::Type<T>;
}
