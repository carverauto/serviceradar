/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

// =============================================================================
// Terminals and interop
// =============================================================================

use crate::{
    CausalFlow, CausalityError, CausalityErrorEnum, PropagatingEffect, PropagatingProcess,
};

impl<Value, State, Context> CausalFlow<Value, State, Context> {
    /// Extract the final value, or the error the flow short-circuited with.
    pub fn finish(self) -> Result<Value, CausalityError> {
        self.inner.outcome.and_then(|value| {
            value
                .into_value()
                .ok_or_else(|| CausalityError::new(CausalityErrorEnum::ValueNotAvailable))
        })
    }

    /// Consume the flow, dispatching to `on_ok` or `on_err` by outcome.
    pub fn run<OnOk, OnErr>(self, on_ok: OnOk, on_err: OnErr)
    where
        OnOk: FnOnce(Value),
        OnErr: FnOnce(CausalityError),
    {
        match self.finish() {
            Ok(v) => on_ok(v),
            Err(e) => on_err(e),
        }
    }

    /// Whether the flow is in the error channel.
    pub fn is_err(&self) -> bool {
        self.inner.is_err()
    }

    /// Drop back to the underlying process for interop with code that expects the concrete type.
    pub fn into_process(self) -> PropagatingProcess<Value, State, Context> {
        self.inner
    }
}

impl<Value> CausalFlow<Value, (), ()> {
    /// Drop back to the underlying stateless effect.
    pub fn into_effect(self) -> PropagatingEffect<Value> {
        self.inner
    }
}

impl<Value, State, Context> From<PropagatingProcess<Value, State, Context>>
    for CausalFlow<Value, State, Context>
{
    fn from(inner: PropagatingProcess<Value, State, Context>) -> Self {
        CausalFlow { inner }
    }
}
