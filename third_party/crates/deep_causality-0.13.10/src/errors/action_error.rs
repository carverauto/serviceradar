/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct ActionError(pub String);

impl ActionError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for ActionError {}

impl fmt::Display for ActionError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "ActionError: {}", self.0)
    }
}

impl From<String> for ActionError {
    fn from(s: String) -> Self {
        ActionError(s)
    }
}

impl From<ActionError> for deep_causality_core::CausalityError {
    fn from(err: ActionError) -> Self {
        deep_causality_core::CausalityError::new(
            deep_causality_core::CausalityErrorEnum::ActionError(err.0),
        )
    }
}
