/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausalEffectPropagationProcess, EffectValue};

// Getters
impl<Value, State, Context, Error, Log>
    CausalEffectPropagationProcess<Value, State, Context, Error, Log>
{
    pub const fn value(&self) -> &EffectValue<Value> {
        &self.value
    }

    pub const fn state(&self) -> &State {
        &self.state
    }

    pub const fn context(&self) -> &Option<Context> {
        &self.context
    }

    pub const fn error(&self) -> &Option<Error> {
        &self.error
    }

    pub const fn logs(&self) -> &Log {
        &self.logs
    }
}
