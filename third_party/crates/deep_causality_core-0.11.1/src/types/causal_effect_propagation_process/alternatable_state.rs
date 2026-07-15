/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use super::CausalEffectPropagationProcess;
use crate::AlternatableState;
use deep_causality_haft::{LogAddEntry, LogAppend};

impl<Value, State, Context, Error, Log> AlternatableState<State>
    for CausalEffectPropagationProcess<Value, State, Context, Error, Log>
where
    Log: LogAppend + LogAddEntry + Default,
{
    fn alternate_state(mut self, new_state: State) -> Self {
        // If there is already an error, propagate it and apply nothing.
        if self.outcome.is_err() {
            return self;
        }

        self.logs.add_entry("!!StateAlternation!!: state replaced");
        self.state = new_state;
        self
    }
}
