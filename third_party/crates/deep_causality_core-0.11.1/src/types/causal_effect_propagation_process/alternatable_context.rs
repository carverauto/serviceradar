/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::CausalEffectPropagationProcess;
use crate::AlternatableContext;
use deep_causality_haft::{LogAddEntry, LogAppend};

impl<Value, State, Context, Error, Log> AlternatableContext<Context>
    for CausalEffectPropagationProcess<Value, State, Context, Error, Log>
where
    Log: LogAppend + LogAddEntry + Default,
{
    fn alternate_context(mut self, new_context: Context) -> Self {
        // If there is already an error, propagate it and apply nothing.
        if self.outcome.is_err() {
            return self;
        }

        self.logs
            .add_entry("!!ContextAlternation!!: context replaced");
        self.context = Some(new_context);
        self
    }
}

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
where
    Log: LogAddEntry,
{
    /// Clear the carried context to `None` — the absence-setting counterpart to
    /// [`alternate_context`](AlternatableContext::alternate_context), whose codomain is `Some(_)`
    /// only. Resolves the gap where a context set mid-chain could never be removed again.
    ///
    /// Symmetric contract with `alternate_context`: a no-op on an errored carrier (an alternation
    /// cannot repair a broken chain), value/state preserved, and one `!!ContextCleared!!` audit
    /// entry appended on success so the substitution is recorded.
    pub fn clear_context(mut self) -> Self {
        if self.outcome.is_err() {
            return self;
        }
        self.logs.add_entry("!!ContextCleared!!: context cleared");
        self.context = None;
        self
    }
}
