/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Fluent steps (hide `EffectValue` + auto short-circuit)
// =============================================================================

use crate::types::causal_flow::{err_leaf, ok_leaf};
use crate::{
    CausalEffectPropagationProcess, CausalFlow, CausalityError, CausalityErrorEnum, EffectLog,
    EffectValue, PropagatingProcess,
};

// The fluent steps lower to the monad's `bind` / `bind_or_error`, which *move* state and context
// through the carrier — they never clone them — so they impose no `Clone` bound on either. The loop
// and branch combinators do not call `bind` and likewise carry no such bound.
impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Full monadic step: the closure receives the unwrapped value and returns the next flow.
    /// Effect-returning stages adapt with [`From`] / `.into()`. Short-circuits on error / no value.
    pub fn and_then<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> CausalFlow<U, State, Context>,
    {
        let inner = self.inner.bind_or_error(
            |v, _state, _context| f(v).inner,
            "and_then received no value",
        );
        CausalFlow { inner }
    }

    /// Compose the next sub-process (a whole pipeline) onto the flow. A pipeline is a function
    /// `Value -> CausalFlow<U>`; `next` is the pipeline-composition verb, lowering to `bind` exactly
    /// as [`and_then`](Self::and_then) does. A reified `CausalArrow` engine value is applied the same
    /// way, with `and_then(|v| arrow.run(v))`.
    pub fn next<U, F>(self, pipeline: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> CausalFlow<U, State, Context>,
    {
        self.and_then(pipeline)
    }

    /// Common stateless step: `Ok` lifts to a value, `Err` to the error channel.
    pub fn try_step<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> Result<U, CausalityError>,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| match f(v) {
                Ok(u) => ok_leaf(u, state, context),
                Err(e) => err_leaf(e, state, context),
            },
            "try_step received no value",
        );
        CausalFlow { inner }
    }

    /// Value transform that mirrors the monad's [`fmap`] contract: apply `f` to a `Value`, pass
    /// `None` and `ContextualLink` carriers through unchanged, and surface a `ValueNotAvailable`
    /// error for the `RelayTo` / `Map` dispatch variants — whose embedded `PropagatingEffect`
    /// cannot be retyped by a value-level map — rather than silently dropping the routing command.
    /// An errored carrier short-circuits (handled by `bind`).
    ///
    /// [`fmap`]: crate::CausalEffectPropagationProcess::fmap
    pub fn map<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> U,
    {
        let inner = self.inner.bind(|ev, state, context| {
            let (value, error) = match ev {
                EffectValue::Value(v) => (EffectValue::Value(f(v)), None),
                EffectValue::None => (EffectValue::None, None),
                EffectValue::ContextualLink(a, b) => (EffectValue::ContextualLink(a, b), None),
                // RelayTo / Map carry a `PropagatingEffect<Value>` a value-level map cannot
                // retype; surface the dropped dispatch command instead of collapsing to `None`.
                _ => (
                    EffectValue::None,
                    Some(CausalityError::new(CausalityErrorEnum::ValueNotAvailable)),
                ),
            };
            CausalEffectPropagationProcess {
                value,
                state,
                context,
                error,
                logs: EffectLog::new(),
            }
        });
        CausalFlow { inner }
    }

    /// Validate the value: `Ok(())` passes it through, `Err` short-circuits.
    pub fn guard<F>(self, f: F) -> Self
    where
        F: FnOnce(&Value) -> Result<(), CausalityError>,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| match f(&v) {
                Ok(()) => ok_leaf(v, state, context),
                Err(e) => err_leaf(e, state, context),
            },
            "guard received no value",
        );
        CausalFlow { inner }
    }

    /// Turn the error channel back into a value. A no-op on a successful flow.
    pub fn recover<F>(self, f: F) -> Self
    where
        F: FnOnce(CausalityError) -> Value,
    {
        match self.inner.error {
            Some(err) => CausalFlow {
                inner: CausalEffectPropagationProcess {
                    value: EffectValue::Value(f(err)),
                    state: self.inner.state,
                    context: self.inner.context,
                    error: None,
                    logs: self.inner.logs,
                },
            },
            None => self,
        }
    }

    /// Stateful step with read-only access to state and context; the facade keeps threading them.
    pub fn try_step_with<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value, &State, Option<&Context>) -> Result<U, CausalityError>,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| match f(v, &state, context.as_ref()) {
                Ok(u) => ok_leaf(u, state, context),
                Err(e) => err_leaf(e, state, context),
            },
            "try_step_with received no value",
        );
        CausalFlow { inner }
    }

    /// Canonical stateful step: mutate the state while transforming the value, in one closure.
    pub fn step_mut<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value, &mut State, Option<&Context>) -> Result<U, CausalityError>,
    {
        let inner = self.inner.bind_or_error(
            |v, mut state, context| match f(v, &mut state, context.as_ref()) {
                Ok(u) => ok_leaf(u, state, context),
                Err(e) => err_leaf(e, state, context),
            },
            "step_mut received no value",
        );
        CausalFlow { inner }
    }

    /// Update the carried value in place; state and context pass through unchanged. A same-typed
    /// sibling of [`map`](Self::map) (which can also change the value's type), kept for symmetry with
    /// the rest of the `update_*` family.
    pub fn update_value<F>(self, f: F) -> Self
    where
        F: FnOnce(Value) -> Value,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| ok_leaf(f(v), state, context),
            "update_value received no value",
        );
        CausalFlow { inner }
    }

    /// Evolve the Markovian state from the current value; the value passes through unchanged. The
    /// closure owns the state and borrows the value.
    pub fn update_state<F>(self, f: F) -> Self
    where
        F: FnOnce(State, &Value) -> State,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| {
                let state = f(state, &v);
                ok_leaf(v, state, context)
            },
            "update_state received no value",
        );
        CausalFlow { inner }
    }

    /// Evolve the read-only context from the current value; the value passes through unchanged. The
    /// closure owns the context and borrows the value.
    pub fn update_context<F>(self, f: F) -> Self
    where
        F: FnOnce(Option<Context>, &Value) -> Option<Context>,
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| {
                let context = f(context, &v);
                ok_leaf(v, state, context)
            },
            "update_context received no value",
        );
        CausalFlow { inner }
    }

    /// Rewrite all three channels at once: the closure owns the value, state, and context and returns
    /// the next triple. This is the one operator that touches value, state, and context together; the
    /// confined `update_value` / `update_state` / `update_context` each evolve a single channel.
    pub fn update_value_state_context<F>(self, f: F) -> Self
    where
        F: FnOnce(Value, State, Option<Context>) -> (Value, State, Option<Context>),
    {
        let inner = self.inner.bind_or_error(
            |v, state, context| {
                let (value, state, context) = f(v, state, context);
                ok_leaf(value, state, context)
            },
            "update_value_state_context received no value",
        );
        CausalFlow { inner }
    }

    /// Drop-in passthrough to the underlying monad's `bind` (accepts an existing stage signature).
    pub fn bind<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(
            EffectValue<Value>,
            State,
            Option<Context>,
        ) -> PropagatingProcess<U, State, Context>,
    {
        CausalFlow {
            inner: self.inner.bind(f),
        }
    }

    /// Drop-in passthrough to the underlying monad's `bind_or_error`.
    pub fn bind_or_error<U, F>(self, f: F, err_msg: &str) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value, State, Option<Context>) -> PropagatingProcess<U, State, Context>,
    {
        CausalFlow {
            inner: self.inner.bind_or_error(f, err_msg),
        }
    }
}
