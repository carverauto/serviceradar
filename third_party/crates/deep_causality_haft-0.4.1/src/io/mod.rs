/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! The lazy IO effect: a deferred description of an input/output computation.
//!
//! IO is the workspace's first genuinely side-effecting effect. Every other effect in the family
//! (the `Error`/`Log`/`State` channels of `CausalEffectPropagationProcess`, the `Effect3/4/5`
//! type-encoded effect system) is *pure* — a fixed type parameter threading **data** through a
//! computation, performing no real-world side effect. IO is different: it executes a **real** effect,
//! so its execution must be deferred to the program edge.
//!
//! # Encoding: the Arrow twin, not a witnessed container
//!
//! A lazy, mono-parametric `Io<A>` (the shape the witness [`Monad`](crate::Monad) trait requires —
//! `F::Type<A>` has one hole) cannot store data-dependent continuations without `Box<dyn FnOnce>`,
//! which this workspace forbids. So IO is realized exactly the way the [`Arrow`](crate::Arrow)
//! algebra is realized: an [`IoAction`] trait whose combinators return **new concrete types**
//! ([`IoMap`], [`IoAndThen`], [`IoMapErr`]). Composition is total and monomorphized, with **no
//! `dyn`, no trait objects, no macros**. An `IoAction` is a nullary arrow `() ⇝ A` in the
//! [`Kleisli`](crate::Kleisli) category of `Result`.
//!
//! The whole module is `no_std`-safe: it uses only `core` (`Result`, closures, `PhantomData`).
//! Concrete file actions (and the filesystem effect itself) live in `deep_causality_core` behind its
//! `std` feature; this layer is generic over the error type so haft names no concrete error.
//!
//! # Laws
//!
//! `IoAction` is a monad; its `and_then` is composition in the [`Kleisli`](crate::Kleisli) category
//! of `Result`. With `pure`/`and_then`/`map`:
//!
//! 1. **Left identity:** `pure(a).and_then(f)` ≡ `f(a)`
//! 2. **Right identity:** `m.and_then(pure)` ≡ `m`
//! 3. **Associativity:** `m.and_then(f).and_then(g)` ≡ `m.and_then(|x| f(x).and_then(g))`
//!
//! (Equivalences hold on the value produced by [`IoAction::run`].)

mod io_and_then;
mod io_fail;
mod io_map;
mod io_map_err;
mod io_pure;

pub use io_and_then::IoAndThen;
pub use io_fail::{IoFail, fail};
pub use io_map::IoMap;
pub use io_map_err::IoMapErr;
pub use io_pure::{IoPure, pure};

/// A deferred description of an input/output computation.
///
/// Constructing an `IoAction` or composing it with [`map`](IoAction::map) /
/// [`and_then`](IoAction::and_then) / [`map_err`](IoAction::map_err) performs **no** side effect.
/// [`run`](IoAction::run) is the only operation permitted to perform one, and it consumes the action
/// (an IO action runs once, at the program edge).
///
/// The combinator methods are provided; an implementor supplies only `Output`, `Error`, and `run`.
#[diagnostic::on_unimplemented(
    message = "`{Self}` is not an `IoAction`",
    note = "construct one with `pure(v)` / `fail(e)`, use a concrete file action (e.g. `deep_causality_core::write_csv`), or implement `IoAction` for your effect type"
)]
pub trait IoAction {
    /// The value the action yields on success.
    type Output;
    /// The failure type threaded through the chain.
    type Error;

    /// Execute the described effect exactly once and return its result. The ONLY method that
    /// performs a side effect.
    fn run(self) -> Result<Self::Output, Self::Error>;

    /// Functor map: transform the successful output, leaving the effect and error channel untouched.
    /// Returns a new concrete `IoAction`; nothing runs until [`run`](IoAction::run).
    #[inline]
    fn map<B, F>(self, f: F) -> IoMap<Self, F>
    where
        Self: Sized,
        F: FnOnce(Self::Output) -> B,
    {
        IoMap::new(self, f)
    }

    /// Monadic bind — composition in the [`Kleisli`](crate::Kleisli) category of `Result`: run
    /// `self`, feed its output to `f`, then run the action `f` returns. Short-circuits on the first
    /// error. Returns a new concrete `IoAction`.
    #[inline]
    fn and_then<P, F>(self, f: F) -> IoAndThen<Self, F>
    where
        Self: Sized,
        P: IoAction<Error = Self::Error>,
        F: FnOnce(Self::Output) -> P,
    {
        IoAndThen::new(self, f)
    }

    /// Transform the error channel, leaving the success path untouched.
    #[inline]
    fn map_err<E2, F>(self, f: F) -> IoMapErr<Self, F>
    where
        Self: Sized,
        F: FnOnce(Self::Error) -> E2,
    {
        IoMapErr::new(self, f)
    }
}
