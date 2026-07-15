/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! Opt-in `PartialEq` / `Eq` / `Debug` for [`Free`], routed through the operation functor's
//! [`EqFunctor`] / [`DebugFunctor`] capability.
//!
//! `Free<F, A>` stores its recursive child under the GAT projection `Suspend(F::Type<Box<Free<F,
//! A>>>)`. A `#[derive]` — or any impl gated on the projection bound `F::Type<Box<Free<F, A>>>:
//! PartialEq` — makes the instance conditional on that projection, so discharging it at a concrete
//! witness re-enters the trait solver and overflows (`error[E0275]`). Routing the recursion through
//! `F::eq_type` / `F::fmt_type` discharges each step against **this** impl's stable bounds
//! (`F: EqFunctor`, `A: PartialEq`) instead — it terminates exactly as a plain recursive `enum List
//! { Nil, Cons(i32, Box<List>) }` does.
//!
//! The instances are additive and opt-in: they exist only when the operation witness `F` implements
//! the capability, so `Free` over a witness that does not is unaffected.

use crate::{DebugFunctor, EqFunctor, Free};
use core::fmt;

/// Structural equality of two programs: equal leaves, or equal operation nodes compared through the
/// functor's `eq_type`. Terminates because the recursive obligation `Box<Free<F, A>>: PartialEq`
/// discharges against this impl.
impl<F, A> PartialEq for Free<F, A>
where
    F: EqFunctor,
    A: PartialEq,
{
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Free::Pure(a), Free::Pure(b)) => a == b,
            (Free::Suspend(x), Free::Suspend(y)) => F::eq_type(x, y),
            _ => false,
        }
    }
}

/// `Eq` is the marker upgrade of the structural `PartialEq`: available when the payload is `Eq` and
/// the functor supplies a (reflexive/symmetric/transitive) `eq_type`.
impl<F, A> Eq for Free<F, A>
where
    F: EqFunctor,
    A: Eq,
{
}

/// `Debug` mirrors the derive shape (`Pure(..)` / `Suspend(..)`), formatting the operation node
/// through the functor's `fmt_type`.
impl<F, A> fmt::Debug for Free<F, A>
where
    F: DebugFunctor,
    A: fmt::Debug,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Free::Pure(a) => {
                f.write_str("Pure(")?;
                fmt::Debug::fmt(a, f)?;
                f.write_str(")")
            }
            Free::Suspend(x) => {
                f.write_str("Suspend(")?;
                F::fmt_type(x, f)?;
                f.write_str(")")
            }
        }
    }
}
