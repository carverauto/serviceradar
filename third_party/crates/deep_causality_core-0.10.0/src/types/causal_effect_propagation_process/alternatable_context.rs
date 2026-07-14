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
        if self.error.is_some() {
            return self;
        }

        self.logs
            .add_entry("!!ContextAlternation!!: context replaced");
        self.context = Some(new_context);
        self
    }
}
