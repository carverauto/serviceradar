/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Branches — conditional routing with flow-endomorphism arms
// =============================================================================
//
// A branch routes the flow to one of two continuations. The arms are flow endomorphisms
// (`CausalFlow<V, S, C> -> CausalFlow<V, S, C>`), so they keep threading state, context, and logs,
// and an arm can itself be a composable sub-pipeline. An errored flow short-circuits without running
// either arm.

use crate::{
    CausalEffect, CausalEffectPropagationProcess, CausalFlow, CausalityError, CausalityErrorEnum,
    Either,
};

impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Route the flow by a predicate over the carried value: `on_true` runs when `cond` holds,
    /// `on_false` otherwise. An errored or value-less flow passes through unchanged.
    pub fn branch<P, T, F>(self, cond: P, on_true: T, on_false: F) -> Self
    where
        P: FnOnce(&Value) -> bool,
        T: FnOnce(Self) -> Self,
        F: FnOnce(Self) -> Self,
    {
        let take_true = self.inner.value().map(cond);
        match take_true {
            Some(true) => on_true(self),
            Some(false) => on_false(self),
            None => self,
        }
    }

    /// Route the flow by a predicate over the carried value, the state, and the context. Otherwise
    /// identical to [`branch`](Self::branch).
    pub fn branch_with<P, T, F>(self, cond: P, on_true: T, on_false: F) -> Self
    where
        P: FnOnce(&Value, &State, Option<&Context>) -> bool,
        T: FnOnce(Self) -> Self,
        F: FnOnce(Self) -> Self,
    {
        let take_true = match self.inner.value() {
            Some(v) => Some(cond(v, &self.inner.state, self.inner.context.as_ref())),
            None => None,
        };
        match take_true {
            Some(true) => on_true(self),
            Some(false) => on_false(self),
            None => self,
        }
    }
}

impl<L, R, State, Context> CausalFlow<Either<L, R>, State, Context> {
    /// Route a flow whose value is `Either<L, R>` to its arm: `left` on `Left`, `right` on `Right`.
    /// An errored flow short-circuits without running either arm. A `None` effect passes through as
    /// a value-less `CausalFlow<U>`; a command effect, which a value-level route cannot retype to
    /// `U`, surfaces a `ValueNotAvailable` error rather than being silently dropped (unreachable-
    /// defensive — the reasoning engine folds commands first).
    pub fn either<U, FL, FR>(self, left: FL, right: FR) -> CausalFlow<U, State, Context>
    where
        FL: FnOnce(CausalFlow<L, State, Context>) -> CausalFlow<U, State, Context>,
        FR: FnOnce(CausalFlow<R, State, Context>) -> CausalFlow<U, State, Context>,
    {
        let (outcome, state, context, logs) = self.inner.into_parts();
        match outcome {
            // An errored carrier carries no `Either`: short-circuit without running an arm.
            Err(error) => CausalFlow {
                inner: CausalEffectPropagationProcess::new(Err(error), state, context, logs),
            },
            // A command effect cannot be retyped to `U`; surface it rather than dropping it.
            Ok(effect) if effect.is_command() => CausalFlow {
                inner: CausalEffectPropagationProcess::new(
                    Err(CausalityError::new(CausalityErrorEnum::ValueNotAvailable)),
                    state,
                    context,
                    logs,
                ),
            },
            Ok(effect) => match effect.into_value() {
                Some(Either::Left(l)) => left(CausalFlow {
                    inner: CausalEffectPropagationProcess::new(
                        Ok(CausalEffect::value(l)),
                        state,
                        context,
                        logs,
                    ),
                }),
                Some(Either::Right(r)) => right(CausalFlow {
                    inner: CausalEffectPropagationProcess::new(
                        Ok(CausalEffect::value(r)),
                        state,
                        context,
                        logs,
                    ),
                }),
                // No value to route: thread the empty carrier through as a value-less `CausalFlow<U>`.
                None => CausalFlow {
                    inner: CausalEffectPropagationProcess::new(
                        Ok(CausalEffect::none()),
                        state,
                        context,
                        logs,
                    ),
                },
            },
        }
    }
}
