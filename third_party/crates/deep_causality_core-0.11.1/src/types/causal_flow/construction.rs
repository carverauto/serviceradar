/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Construction (hides `pure` / `with_state` / the witnesses)
// =============================================================================

use crate::types::causal_flow::{err_leaf, ok_leaf};
use crate::{CausalEffect, CausalEffectPropagationProcess, CausalFlow, CausalityError, EffectLog};

impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Build a flow from explicit channels — the general constructor beneath [`value`](CausalFlow::value)
    /// and [`process`](CausalFlow::process), and the causal arrow's unit `η`:
    /// `η(a, s, c) = from_parts(Ok(CausalEffect::value(a)), s, c, EffectLog::new())`.
    pub fn from_parts(
        outcome: Result<CausalEffect<Value>, CausalityError>,
        state: State,
        context: Option<Context>,
        logs: EffectLog,
    ) -> Self {
        CausalFlow {
            inner: CausalEffectPropagationProcess::new(outcome, state, context, logs),
        }
    }
}

impl CausalFlow<(), (), ()> {
    /// Start a stateless flow carrying the unit value (the seed for an effect chain).
    pub fn effect() -> Self {
        CausalFlow {
            inner: ok_leaf((), (), None),
        }
    }
}

impl<Value> CausalFlow<Value, (), ()> {
    /// Start a stateless flow carrying `value`.
    pub fn value(value: Value) -> Self {
        CausalFlow {
            inner: ok_leaf(value, (), None),
        }
    }

    /// Start a flow already in the error channel.
    pub fn fail(err: CausalityError) -> Self {
        CausalFlow {
            inner: err_leaf(err, (), None),
        }
    }
}

impl<State> CausalFlow<(), State, ()> {
    /// Start a stateful flow with an initial `state` (lowers to `with_state(pure(()), state, None)`).
    pub fn process(state: State) -> Self {
        CausalFlow {
            inner: ok_leaf((), state, None),
        }
    }
}

impl<Value, State> CausalFlow<Value, State, ()> {
    /// Attach a read-only context, promoting the flow to its stateful/contextful form.
    pub fn context<Context>(self, context: Context) -> CausalFlow<Value, State, Context> {
        let inner = self.inner;
        CausalFlow {
            inner: CausalEffectPropagationProcess::new(
                inner.outcome,
                inner.state,
                Some(context),
                inner.logs,
            ),
        }
    }
}
