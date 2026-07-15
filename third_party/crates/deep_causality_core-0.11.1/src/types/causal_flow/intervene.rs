/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Value alternation (counterfactual substitution on the value channel)
// =============================================================================
//
// This is the value-substitution lens, `alternate_value`. It is NOT Pearl's `do(...)` operator:
// that is graph surgery (parent-edge deletion / variable isolation) and lives at the
// `deep_causality` Causaloid + hypergraph layer, where a graph is in scope. At the value/monad
// level there is no graph to mutilate, so the honest operation is counterfactual value substitution.

use crate::{AlternatableValue, CausalFlow};
use core::fmt::Debug;

impl<Value, State, Context> CausalFlow<Value, State, Context>
where
    Value: Debug,
{
    /// Substitute the carried value with `new_value` (counterfactual value substitution),
    /// recording the override in the audit log. A no-op on a failed flow (the underlying
    /// `AlternatableValue` preserves the error).
    pub fn alternate_value(self, new_value: Value) -> Self {
        CausalFlow {
            inner: self.inner.alternate_value(new_value),
        }
    }
}

impl<Value, State, Context> CausalFlow<Value, State, Context>
where
    Value: Debug + Clone,
{
    /// Alternate only when `cond` holds over the current value: replace it with `f(value)` and log
    /// the override; otherwise pass the value through untouched.
    pub fn alternate_value_if<P, F>(self, cond: P, f: F) -> Self
    where
        P: FnOnce(&Value) -> bool,
        F: FnOnce(Value) -> Value,
    {
        // An errored flow short-circuits without running `cond` or `f`, consistent with
        // `alternate_value` (a no-op on a failed flow). Value and error are one channel, so the
        // formerly representable "value AND error" carrier — which would have executed the
        // user closures before the substitution discarded them — cannot exist.
        match &self.inner.outcome {
            Ok(value) => match value.clone().into_value() {
                Some(v) if cond(&v) => self.alternate_value(f(v)),
                _ => self,
            },
            Err(_) => self,
        }
    }
}
