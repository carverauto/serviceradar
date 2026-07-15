/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_effect_propagation_process::CausalEffectPropagationProcess;

impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
{
    /// Returns `true` if the process carries an effect value (no error).
    pub const fn is_ok(&self) -> bool {
        self.outcome.is_ok()
    }

    /// Returns `true` if the process holds an error.
    pub const fn is_err(&self) -> bool {
        self.outcome.is_err()
    }
}
