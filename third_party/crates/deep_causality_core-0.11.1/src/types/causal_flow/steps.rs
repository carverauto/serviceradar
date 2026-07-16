/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Fluent steps (hide `CausalEffect` + auto short-circuit)
// =============================================================================

use crate::types::causal_flow::{err_leaf, ok_leaf};
use crate::{
    CausalEffect, CausalEffectPropagationProcess, CausalFlow, CausalityError, CausalityErrorEnum,
    EffectLog, PropagatingProcess,
};

// The fluent steps lower to the monad's `bind` / `bind_or_error`, which *move* state and context
// through the carrier — they never clone them — so they impose no `Clone` bound on either. The loop
// and branch combinators do not call `bind` and likewise carry no such bound.
impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// The Kleisli bind of the causal monad — the one lawful sequencing step.
    ///
    /// The continuation receives `(value, state, context)` and returns the next flow, whose
    /// state/context are threaded **forward** (`s0 → s1 → s2`) exactly as the monad's
    /// [`bind`](crate::CausalEffectPropagationProcess::bind) threads them (`CausalMonad.lean ::
    /// bind'`). The stateless case is a *specialization*, not a separate operation: with
    /// `State = Context = ()` there is nothing to thread, so a stage written `|v, _, _| …` behaves
    /// exactly as a value-only step would — which is why there is a single `and_then`, not a
    /// value-only/stateful pair.
    ///
    /// A `None` effect short-circuits *lawfully*, mirroring [`map`](Self::map) and the Maybe monad:
    /// it passes through unchanged (the continuation is NOT run and no error is manufactured), which
    /// is what makes right identity `f >=> η = f` hold. A command effect carries a control
    /// sub-program a value-level step cannot retype to `U`, so it surfaces a `ValueNotAvailable`
    /// error rather than being dropped (unreachable-defensive — the reasoning engine folds commands
    /// first). An upstream error short-circuits (left zero, handled by `bind`). Effect-returning
    /// stages adapt with [`From`] / `.into()`.
    pub fn and_then<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value, State, Option<Context>) -> CausalFlow<U, State, Context>,
    {
        let inner = self.inner.bind(|effect, state, context| {
            if effect.is_command() {
                // A command cannot be retyped by a value-level step; the reasoning engine folds it
                // first, so this is unreachable-defensive.
                return CausalEffectPropagationProcess::new(
                    Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable)),
                    state,
                    context,
                    EffectLog::new(),
                );
            }
            match effect.into_value() {
                // Run the continuation on the threaded `(value, state, context)`, threading its
                // returned state/context forward; `bind` prepends the upstream logs.
                Some(v) => f(v, state, context).inner,
                // A `None` effect short-circuits lawfully: continuation not run, channel preserved.
                None => CausalEffectPropagationProcess::new(
                    Ok(CausalEffect::none()),
                    state,
                    context,
                    EffectLog::new(),
                ),
            }
        });
        CausalFlow { inner }
    }

    /// The everyday value-only step: a stage `Fn(Value) -> CausalFlow<U>` that ignores state/context,
    /// i.e. exactly `and_then(|v, _, _| pipeline(v))`. This is the drop-in for the vast majority of
    /// pipelines; [`and_then`](Self::and_then) is the rarely-needed stateful form for stages that must
    /// read or evolve state. It is **not** a second bind — just `and_then` with the state/context
    /// inputs pre-ignored — so for stateless flows (`State = Context = ()`) the two coincide.
    pub fn next<U, F>(self, pipeline: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> CausalFlow<U, State, Context>,
    {
        self.and_then(|v, _state, _context| pipeline(v))
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

    /// Value transform — the fluent functor. Maps the carried value through the **total**
    /// [`CausalEffect::map`]: a value maps its leaf, a `None` passes through unchanged, and a command
    /// is **preserved** (its sub-program's value leaf mapped through the `RelayTo` tree). It never
    /// errors on a command and never panics; an errored carrier short-circuits (via `bind`). Contrast
    /// [`and_then`](Self::and_then), a value-level Kleisli step whose continuation needs a value, so
    /// it cannot run under a command (the engine folds commands first) — hence `map` and
    /// `and_then(pure ∘ f)` coincide on the value fragment but not on a command.
    ///
    /// (This is the loose-bounds sibling of the carrier's
    /// [`fmap`](crate::CausalEffectPropagationProcess::fmap); both route through `CausalEffect::map`,
    /// so the value/none/command mapping lives in one place.)
    pub fn map<U, F>(self, f: F) -> CausalFlow<U, State, Context>
    where
        F: FnOnce(Value) -> U,
    {
        let inner = self.inner.bind(|effect, state, context| {
            // Total functor: value/none/command are all handled by `CausalEffect::map`.
            CausalEffectPropagationProcess::new(Ok(effect.map(f)), state, context, EffectLog::new())
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
        match self.inner.outcome {
            Err(err) => CausalFlow {
                inner: CausalEffectPropagationProcess::new(
                    Ok(CausalEffect::value(f(err))),
                    self.inner.state,
                    self.inner.context,
                    self.inner.logs,
                ),
            },
            Ok(value) => CausalFlow {
                inner: CausalEffectPropagationProcess::new(
                    Ok(value),
                    self.inner.state,
                    self.inner.context,
                    self.inner.logs,
                ),
            },
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
            CausalEffect<Value>,
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
