/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # `CausalEffect`: the effect of the effect-propagation process
//!
//! `CausalEffect<V>` is the **success channel** of a causal computation — a value **or** a command.
//! It is a thin newtype over the free monad on the control operation functor
//! [`CausalCommand`](crate::CausalCommand), with `Option<V>` (Maybe) value leaves:
//!
//! ```text
//! CausalEffect<V>  =  Free<CausalCommandWitness, Option<V>>
//!   Pure(None)            = no value / absence of evidence
//!   Pure(Some(v))        = a value
//!   Suspend(RelayTo(t,k)) = an adaptive-reasoning jump (a command), k the sub-program
//! ```
//!
//! Together with the carrier's error channel this makes the outcome
//! `Result<CausalEffect<V>, Error>` = `Except E (Free CausalCommand (Maybe V))` — a monad transformer
//! stack of three already-proven monads (`Except`, the free monad `haft.free_monad.*`, and `Maybe`).
//! Value/none/command are unified as `Pure`/`Suspend`; the value-level monad ([`CausalMonad`]) works
//! on the `Pure(Option V)` fragment exactly as `CausalMonad.lean` proves, and the reasoning engine is
//! the [`fold`](CausalEffect::fold) handler that interprets the command layer.
//!
//! [`CausalMonad`]: crate::CausalMonad

use crate::types::causal_command::{CausalCommand, CausalCommandWitness};
use alloc::boxed::Box;
use deep_causality_haft::Free;

/// The internal free-monad program: `Pure(Option<V>)` leaves, `Suspend(RelayTo(..))` control nodes.
type Program<V> = Free<CausalCommandWitness, Option<V>>;

/// The effect of the effect-propagation process — a value or a command. See the module docs.
pub struct CausalEffect<V>(Program<V>);

impl<V> CausalEffect<V> {
    // -- Constructors ---------------------------------------------------------------------------

    /// A value effect (`Pure(Some(v))`).
    #[inline]
    pub fn value(v: V) -> Self {
        CausalEffect(Free::Pure(Some(v)))
    }

    /// The absence-of-evidence effect (`Pure(None)`).
    #[inline]
    pub fn none() -> Self {
        CausalEffect(Free::Pure(None))
    }

    /// Build from a `Maybe` value directly (`Pure(o)`).
    #[inline]
    pub fn from_option(o: Option<V>) -> Self {
        CausalEffect(Free::Pure(o))
    }

    /// A command effect: jump to the causaloid at `target`, feeding it the sub-effect `input`
    /// (`Suspend(RelayTo(target, input))`).
    #[inline]
    pub fn relay_to(target: usize, input: CausalEffect<V>) -> Self {
        CausalEffect(Free::Suspend(CausalCommand::RelayTo(
            target,
            Box::new(input.0),
        )))
    }

    // -- Discriminators -------------------------------------------------------------------------

    /// Whether this is the `None` (no-value) effect.
    #[inline]
    pub fn is_none(&self) -> bool {
        matches!(&self.0, Free::Pure(None))
    }

    /// Whether this carries a value.
    #[inline]
    pub fn is_value(&self) -> bool {
        matches!(&self.0, Free::Pure(Some(_)))
    }

    /// Whether this is a control command (a jump).
    #[inline]
    pub fn is_command(&self) -> bool {
        matches!(&self.0, Free::Suspend(_))
    }

    // -- Value access ---------------------------------------------------------------------------

    /// Borrow the carried scalar, if this is `Pure(Some(v))`.
    #[inline]
    pub fn as_value(&self) -> Option<&V> {
        match &self.0 {
            Free::Pure(Some(v)) => Some(v),
            _ => None,
        }
    }

    /// Consume and return the carried scalar, if any (`Pure(Some(v)) → Some(v)`; else `None`).
    #[inline]
    pub fn into_value(self) -> Option<V> {
        match self.0 {
            Free::Pure(opt) => opt,
            Free::Suspend(_) => None,
        }
    }

    // -- Command access -------------------------------------------------------------------------

    /// The command's target causaloid index, if this is a command (borrowing).
    #[inline]
    pub fn command_target(&self) -> Option<usize> {
        match &self.0 {
            Free::Suspend(CausalCommand::RelayTo(t, _)) => Some(*t),
            Free::Pure(_) => None,
        }
    }

    /// Consume a command into `(target, sub_effect)`, if this is a command. The reasoning handler
    /// jumps to `target` feeding it `sub_effect`.
    #[inline]
    pub fn into_command(self) -> Option<(usize, CausalEffect<V>)> {
        match self.0 {
            Free::Suspend(CausalCommand::RelayTo(t, sub)) => Some((t, CausalEffect(*sub))),
            Free::Pure(_) => None,
        }
    }

    // -- Functor / handler ----------------------------------------------------------------------

    /// The **total** functor map: apply `f` to the `Option<V>` value leaf, threading through the
    /// command tree so a command is preserved (its single sub-program leaf is mapped). No error, no
    /// panic. `FnOnce` suffices and is the most permissive bound: the `RelayTo` operation is
    /// single-hole, so the program is a linear chain with exactly one `Pure` value leaf, and `f` is
    /// applied at most once.
    pub fn map<U, F>(self, f: F) -> CausalEffect<U>
    where
        F: FnOnce(V) -> U,
    {
        CausalEffect(map_program(self.0, f))
    }

    /// The catamorphism / algebraic-effect handler: interpret the program. `pure_case` gives meaning
    /// to a value leaf; `algebra` interprets a `RelayTo(target, folded_sub)` command node. This is
    /// the `Free::fold` the reasoning engine specializes.
    ///
    /// `fold` satisfies the two handler equations definitionally and is the **unique** function
    /// that does — the interpreter is determined by its value case and its command algebra
    /// (initiality of the free monad). Machine-checked as `core.causal_effect.fold_universal` in
    /// `lean/DeepCausalityFormal/Core/CausalEffect.lean`.
    pub fn fold<X, P, A>(self, pure_case: &P, algebra: &A) -> X
    where
        P: Fn(Option<V>) -> X,
        A: Fn(usize, X) -> X,
    {
        fold_program(self.0, pure_case, algebra)
    }

    // -- Monad structure (the success channel of the transformer stack) --------------------------

    /// The success-channel monad bind (the `Free ∘ Maybe` layer): dispatch on the effect —
    /// a `None` leaf is a **local zero** (preserved where it is), a value leaf runs the
    /// continuation, and a `RelayTo` node threads the bind under the command. The operation is
    /// single-hole, so the continuation is applied at most once and `FnOnce` suffices.
    ///
    /// Together with the carrier's error channel (`Result`, the outermost `Except` layer;
    /// see [`try_and_then`](Self::try_and_then)) this is the lawful monad of the outcome
    /// `Except E (Free CausalCommand (Maybe V))` — machine-checked as
    /// `core.causal_effect.transformer_stack` in `lean/DeepCausalityFormal/Core/CausalEffect.lean`.
    pub fn and_then<W, F>(self, k: F) -> CausalEffect<W>
    where
        F: FnOnce(V) -> CausalEffect<W>,
    {
        CausalEffect(and_then_program(self.0, k))
    }

    /// The full transformer-stack bind: like [`and_then`](Self::and_then), but the continuation may
    /// fail, and an error produced **inside a relayed sub-program is hoisted outward** — the
    /// `Except` layer is outermost, so an inner failure aborts the whole outcome (exactly the
    /// engine's node-error short-circuit). `Ok`-side structure is preserved: `None` stays a local
    /// zero, a relay node keeps its target.
    ///
    /// This is the Rust realization of the composite `obind` proved lawful as
    /// `core.causal_effect.transformer_stack` (left/right identity, associativity, the error
    /// left-zero, and the `None` local zero).
    pub fn try_and_then<W, E, F>(self, k: F) -> Result<CausalEffect<W>, E>
    where
        F: FnOnce(V) -> Result<CausalEffect<W>, E>,
    {
        try_and_then_program(self.0, k).map(CausalEffect)
    }
}

/// Map the single value leaf of a program. `RelayTo` is single-hole, so the program is a linear
/// chain: `f` is moved down through the command nodes to the one `Pure` leaf and applied there once
/// (hence `FnOnce`).
fn map_program<V, U, F>(p: Program<V>, f: F) -> Program<U>
where
    F: FnOnce(V) -> U,
{
    match p {
        Free::Pure(opt) => Free::Pure(opt.map(f)),
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => {
            Free::Suspend(CausalCommand::RelayTo(t, Box::new(map_program(*sub, f))))
        }
    }
}

/// Fold a program to `X` via a value case and a command algebra.
fn fold_program<V, X, P, A>(p: Program<V>, pure_case: &P, algebra: &A) -> X
where
    P: Fn(Option<V>) -> X,
    A: Fn(usize, X) -> X,
{
    match p {
        Free::Pure(opt) => pure_case(opt),
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => {
            algebra(t, fold_program(*sub, pure_case, algebra))
        }
    }
}

/// Bind the single value leaf of a program (`Free ∘ Maybe`): `Pure(None)` is a local zero,
/// `Pure(Some v)` runs the continuation, a `RelayTo` node threads the bind under the command.
/// Single-hole, so `k` is applied at most once (`FnOnce`).
fn and_then_program<V, W, F>(p: Program<V>, k: F) -> Program<W>
where
    F: FnOnce(V) -> CausalEffect<W>,
{
    match p {
        Free::Pure(None) => Free::Pure(None),
        Free::Pure(Some(v)) => k(v).0,
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => Free::Suspend(CausalCommand::RelayTo(
            t,
            Box::new(and_then_program(*sub, k)),
        )),
    }
}

/// The full-stack bind (`Except` outermost): an error from the continuation — even under a relay
/// node — aborts the whole outcome; `Ok`-side structure is preserved.
fn try_and_then_program<V, W, E, F>(p: Program<V>, k: F) -> Result<Program<W>, E>
where
    F: FnOnce(V) -> Result<CausalEffect<W>, E>,
{
    match p {
        Free::Pure(None) => Ok(Free::Pure(None)),
        Free::Pure(Some(v)) => k(v).map(|e| e.0),
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => {
            let w = try_and_then_program(*sub, k)?;
            Ok(Free::Suspend(CausalCommand::RelayTo(t, Box::new(w))))
        }
    }
}

// `Free` derives none of these (recursive-GAT trait-solver limit); the impls walk the finite
// `RelayTo` tree of `Option<V>` leaves — a lawful congruent equality (unlike the removed `Map` PER).

impl<V: Clone> Clone for CausalEffect<V> {
    fn clone(&self) -> Self {
        CausalEffect(clone_program(&self.0))
    }
}

fn clone_program<V: Clone>(p: &Program<V>) -> Program<V> {
    match p {
        Free::Pure(opt) => Free::Pure(opt.clone()),
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => {
            Free::Suspend(CausalCommand::RelayTo(*t, Box::new(clone_program(sub))))
        }
    }
}

impl<V: PartialEq> PartialEq for CausalEffect<V> {
    fn eq(&self, other: &Self) -> bool {
        program_eq(&self.0, &other.0)
    }
}

fn program_eq<V: PartialEq>(a: &Program<V>, b: &Program<V>) -> bool {
    match (a, b) {
        (Free::Pure(x), Free::Pure(y)) => x == y,
        (
            Free::Suspend(CausalCommand::RelayTo(ta, sa)),
            Free::Suspend(CausalCommand::RelayTo(tb, sb)),
        ) => ta == tb && program_eq(sa, sb),
        _ => false,
    }
}

impl<V: core::fmt::Debug> core::fmt::Debug for CausalEffect<V> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        debug_program(&self.0, f)
    }
}

fn debug_program<V: core::fmt::Debug>(
    p: &Program<V>,
    f: &mut core::fmt::Formatter<'_>,
) -> core::fmt::Result {
    match p {
        Free::Pure(None) => write!(f, "None"),
        Free::Pure(Some(v)) => write!(f, "Value({v:?})"),
        Free::Suspend(CausalCommand::RelayTo(t, sub)) => {
            write!(f, "RelayTo({t}, ")?;
            debug_program(sub, f)?;
            write!(f, ")")
        }
    }
}

impl<V> Default for CausalEffect<V> {
    /// The default effect is the absence of evidence (`None`).
    #[inline]
    fn default() -> Self {
        CausalEffect::none()
    }
}
