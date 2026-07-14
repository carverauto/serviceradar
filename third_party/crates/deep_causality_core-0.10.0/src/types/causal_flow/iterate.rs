/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Bounded loops — the causal `EndoArrow`
// =============================================================================
//
// A loop iterates a *flow endomorphism* `CausalFlow<V, S, C> -> CausalFlow<V, S, C>`, the causal
// analogue of `deep_causality_haft::EndoArrow` (there the carrier is `S` and the step is `S -> S`;
// here the carrier is the flow). Every step threads value, state, context, and logs, and an error
// short-circuits the loop. `iterate_until` / `iterate_to_fixpoint` fail with `MaxStepsExceeded` when
// the step bound is reached without meeting their condition, keeping one short-circuit mechanism
// across the flow DSL and the monad.

use crate::{
    CausalEffectPropagationProcess, CausalFlow, CausalityError, CausalityErrorEnum, EffectValue,
};

impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Apply the flow endomorphism `step` exactly `n` times. An error mid-way short-circuits and
    /// skips the remaining iterations.
    pub fn iterate_n<F>(self, n: usize, step: F) -> Self
    where
        F: Fn(Self) -> Self,
    {
        let mut flow = self;
        for _ in 0..n {
            if flow.is_err() {
                break;
            }
            flow = step(flow);
        }
        flow
    }

    /// Apply `step` until `pred` holds over the carried value or `max_steps` is reached. The
    /// predicate is checked before each step. Reaching the bound without `pred` short-circuits with
    /// a `MaxStepsExceeded` error.
    pub fn iterate_until<P, F>(self, pred: P, max_steps: usize, step: F) -> Self
    where
        P: Fn(&Value) -> bool,
        F: Fn(Self) -> Self,
    {
        let mut flow = self;
        if flow.is_err() {
            return flow;
        }
        if flow.value_satisfies(&pred) {
            return flow;
        }
        for _ in 0..max_steps {
            flow = step(flow);
            if flow.is_err() {
                return flow;
            }
            if flow.value_satisfies(&pred) {
                return flow;
            }
        }
        flow.fail_not_converged()
    }

    /// Apply `step` until the carried value stops changing or `max_steps` is reached. Reaching the
    /// bound without a fixpoint short-circuits with a `MaxStepsExceeded` error.
    pub fn iterate_to_fixpoint<F>(self, max_steps: usize, step: F) -> Self
    where
        Value: Clone + PartialEq,
        F: Fn(Self) -> Self,
    {
        let mut flow = self;
        if flow.is_err() {
            return flow;
        }
        for _ in 0..max_steps {
            let prev = flow.peek_value().cloned();
            flow = step(flow);
            if flow.is_err() {
                return flow;
            }
            if let (Some(prev), Some(next)) = (prev.as_ref(), flow.peek_value())
                && prev == next
            {
                return flow;
            }
        }
        flow.fail_not_converged()
    }
}

// Private helpers (no extra bounds): they read the carrier directly.
impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// A reference to the carried value, if the flow holds one.
    #[inline]
    fn peek_value(&self) -> Option<&Value> {
        match &self.inner.value {
            EffectValue::Value(v) => Some(v),
            _ => None,
        }
    }

    /// Whether the carried value satisfies `pred` (false when there is no value).
    #[inline]
    fn value_satisfies<P: Fn(&Value) -> bool>(&self, pred: &P) -> bool {
        self.peek_value().is_some_and(pred)
    }

    /// Replace the flow with a `MaxStepsExceeded` error, preserving state, context, and logs.
    #[inline]
    fn fail_not_converged(self) -> Self {
        CausalFlow {
            inner: CausalEffectPropagationProcess {
                value: EffectValue::None,
                state: self.inner.state,
                context: self.inner.context,
                error: Some(CausalityError::new(CausalityErrorEnum::MaxStepsExceeded)),
                logs: self.inner.logs,
            },
        }
    }
}
