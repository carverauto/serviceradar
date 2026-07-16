/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::types::causal_effect_propagation_process::CausalEffectPropagationProcess;
use core::fmt::{Debug, Display, Formatter};

impl<Value: Debug, Error: Debug, Log: Debug> Display
    for CausalEffectPropagationProcess<Value, (), (), Error, Log>
{
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        // Delegate to custom debug implementation to prevent infinite recursion.
        write!(f, "{self:?}")
    }
}
