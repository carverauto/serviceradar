/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::{ActionParameterValue, UncertainParameter};
use deep_causality_core::CausalityError;

/// Trait for types that can be evaluated to a boolean decision in a CSM.
pub trait CsmEvaluable {
    /// Determines if the state is active based on the value and optional parameters.
    fn is_active(&self, params: Option<&UncertainParameter>) -> Result<bool, CausalityError>;
    /// Converts the value to an ActionParameterValue for use in actions.
    fn to_action_param(&self) -> ActionParameterValue;
}
