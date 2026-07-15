/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # The Causal Arrow engine
//!
//! A reusable Kleisli arrow over the causal monad: a value `A -> CausalFlow<B, S, C>` that can be
//! built once, stored, and run on many inputs. It is the *engine* beneath the flow DSL; the routine
//! way to compose pipelines is the `CausalFlow` DSL (`next`), which never names these types. Reach
//! for the engine only when a composite must be held as data.
//!
//! ## Relationship to the pure Arrow algebra
//!
//! The carriers implement [`deep_causality_haft::Arrow`]: pure `haft` Arrow is *the* category;
//! the Causal Arrow is its **Kleisli category** over `CausalEffectPropagationProcess`. Same arrow
//! shape, different composition law — [`KleisliCompose`] binds where `haft::Compose` applies.
//!
//! ```
//! use deep_causality_core::{causal_arrow, CausalFlow};
//!
//! // Stages receive `(value, state, context)`; a stateless stage ignores the last two.
//! let inc = causal_arrow(|x: i64, _s, _c| CausalFlow::value(x + 1));
//! let dbl = inc.next(|x, _s, _c| CausalFlow::value(x * 2)); // (x + 1) * 2, reusable
//! assert_eq!(dbl.run_value(3).finish(), Ok(8));
//! assert_eq!(dbl.run_value(4).finish(), Ok(10));
//! ```

mod builder;
mod compose;
mod lift;

pub use builder::{CausalArrowBuilder, causal_arrow};
pub use compose::KleisliCompose;
pub use lift::CausalLift;

use crate::CausalFlow;
use deep_causality_haft::Arrow;

/// Destructures a causal arrow's output (`CausalFlow<Value, State, Context>`) into its parts.
///
/// Kleisli composition needs the value, state, and context of an arrow's output to wire the next
/// stage. The `Arrow` trait exposes only the whole `Out` type, so this helper projects it. It is
/// implemented for `CausalFlow` and nothing else.
pub trait CausalFlowOut {
    /// The carried value type.
    type Value;
    /// The state channel type.
    type State;
    /// The context channel type.
    type Context;
    /// Recover the concrete `CausalFlow`.
    fn into_causal_flow(self) -> CausalFlow<Self::Value, Self::State, Self::Context>;
}

impl<V, S, C> CausalFlowOut for CausalFlow<V, S, C> {
    type Value = V;
    type State = S;
    type Context = C;

    #[inline]
    fn into_causal_flow(self) -> CausalFlow<V, S, C> {
        self
    }
}

/// A reusable Kleisli arrow `(A, S, Option<C>) -> CausalFlow<B, S, C>`: the engine's nameable bound.
///
/// Any [`Arrow`] whose input is `(A, S, Option<C>)` and whose output is a `CausalFlow<B, S, C>` is a
/// `CausalArrow`. Use it as a bound (for example `impl CausalArrow<Raw, Command>`) to name an engine
/// composite without spelling out the nested combinator types.
pub trait CausalArrow<A, B, S = (), C = ()>:
    Arrow<In = (A, S, Option<C>), Out = CausalFlow<B, S, C>>
{
}

impl<T, A, B, S, C> CausalArrow<A, B, S, C> for T where
    T: Arrow<In = (A, S, Option<C>), Out = CausalFlow<B, S, C>>
{
}
