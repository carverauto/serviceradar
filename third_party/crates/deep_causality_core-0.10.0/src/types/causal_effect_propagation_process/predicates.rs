/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_effect_propagation_process::CausalEffectPropagationProcess;
use deep_causality_haft::LogSize;

impl<Value, Error, Log> CausalEffectPropagationProcess<Value, (), (), Error, Log>
where
    Log: LogSize,
{
    pub const fn is_ok(&self) -> bool {
        self.error.is_none()
    }

    pub const fn is_err(&self) -> bool {
        self.error.is_some()
    }
}
