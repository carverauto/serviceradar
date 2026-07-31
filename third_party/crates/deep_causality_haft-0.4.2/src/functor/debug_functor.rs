/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{HKT, NoConstraint};
use core::fmt;

/// Witness capability: an [`HKT`] functor whose `Type<T>` can be `Debug`-formatted whenever the
/// payload `T: Debug`.
///
/// This is the [`core::fmt::Debug`] analogue of [`Functor`](crate::Functor) and the twin of
/// [`EqFunctor`](crate::EqFunctor): the witness supplies the formatting of its container, which
/// gives the recursive carriers `Free` and `Cofree` their `Debug` instances without the
/// trait-solver overflow a `#[derive]` (or a `Self::Type<..>: Debug` field bound) hits on the GAT
/// projection `Self::Type<Box<Free<F, A>>>` (see [`EqFunctor`](crate::EqFunctor) for the mechanism).
///
/// # Opt-in
///
/// A witness opts in by implementing this trait. The crate's built-in single-hole functor witnesses
/// (`OptionWitness`, `VecWitness`, `BoxWitness`, `LinkedListWitness`, `VecDequeWitness`) implement it
/// — the body delegates to the container's own `Debug`.
///
/// Scoped to `HKT<Constraint = NoConstraint>` because `Free`/`Cofree` require it.
///
/// # Examples
///
/// ```rust
/// use deep_causality_haft::{DebugFunctor, OptionWitness};
///
/// // `OptionWitness` implements `DebugFunctor`, so any `Free`/`Cofree` over it is `Debug`.
/// fn assert_debug_functor<W: DebugFunctor>() {}
/// assert_debug_functor::<OptionWitness>();
/// ```
pub trait DebugFunctor: HKT<Constraint = NoConstraint> {
    /// `Debug`-format a `Self::Type<T>` container into `f`, given `T: Debug`.
    fn fmt_type<T: fmt::Debug>(fa: &Self::Type<T>, f: &mut fmt::Formatter<'_>) -> fmt::Result;
}
