/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! # `CausalFlow`: a fluent facade over the causal monad
//!
//! [`CausalFlow`] is a thin builder over [`CausalEffectPropagationProcess`] (through the
//! [`PropagatingEffect`] / [`PropagatingProcess`] aliases). It hides the HKT witness types, the
//! verbose constructors (`pure` / `with_state`), the [`CausalEffect`](crate::CausalEffect) wrapping, and the manual error
//! short-circuit, so a pipeline reads as a clean flow. Every method lowers to an existing monad
//! operation, so the facade adds sugar, not new semantics.
//!
//! ```
//! use deep_causality_core::CausalFlow;
//!
//! let outcome = CausalFlow::value(2_i64)
//!     .try_step(|x| Ok(x + 3))
//!     .map(|x| x * 10)
//!     .finish();
//! assert_eq!(outcome, Ok(50));
//! ```
//!
//! Control flow — a bounded loop whose body branches on the carried value:
//!
//! ```
//! use deep_causality_core::CausalFlow;
//!
//! let total = CausalFlow::value(0_i64)
//!     .iterate_n(5, |tick| {
//!         tick.branch(|n| n % 2 == 0, |even| even.map(|n| n + 10), |odd| odd.map(|n| n + 1))
//!     })
//!     .finish();
//! assert_eq!(total, Ok(50)); // every value stays even, so +10 five times
//! ```

mod branch;
mod construction;
mod intervene;
mod io;
mod iterate;
mod steps;
mod terminals;

use crate::{
    CausalEffect, CausalEffectPropagationProcess, CausalityError, EffectLog, PropagatingProcess,
};
use core::fmt::Debug;

/// A fluent flow over the causal monad. `State` and `Context` default to `()`, so `CausalFlow<T>`
/// is the stateless form (lowering to [`crate::PropagatingEffect`]); a non-unit `State`/`Context` lowers
/// to [`PropagatingProcess`]. `Error` and `Log` are fixed to [`CausalityError`] / [`EffectLog`], so
/// the witness types never appear in a signature a caller reads.
#[derive(Debug, Clone, PartialEq)]
pub struct CausalFlow<Value, State = (), Context = ()> {
    inner: PropagatingProcess<Value, State, Context>,
}

// Free helpers building a leaf process with an empty log (so `bind`/`bind_or_error` carry only the
// upstream logs forward).
#[inline]
fn ok_leaf<U, State, Context>(
    value: U,
    state: State,
    context: Option<Context>,
) -> PropagatingProcess<U, State, Context> {
    CausalEffectPropagationProcess::new(
        Ok(CausalEffect::value(value)),
        state,
        context,
        EffectLog::new(),
    )
}

#[inline]
fn err_leaf<U, State, Context>(
    err: CausalityError,
    state: State,
    context: Option<Context>,
) -> PropagatingProcess<U, State, Context> {
    CausalEffectPropagationProcess::new(Err(err), state, context, EffectLog::new())
}
