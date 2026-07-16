/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalityGraphError;
use deep_causality_uncertain::UncertainError;
use std::error::Error;
use std::fmt;
use ultragraph::GraphError;

#[derive(Debug, Clone, PartialOrd, PartialEq)]
pub struct CausalityError(pub String);

impl CausalityError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for CausalityError {}

impl fmt::Display for CausalityError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "CausalityError: {}", self.0)
    }
}

impl From<GraphError> for CausalityError {
    fn from(err: GraphError) -> Self {
        // Convert the specific graph error into a descriptive string
        // and wrap it in our custom error type.
        CausalityError(format!("Graph operation failed: {err}"))
    }
}

impl From<CausalityGraphError> for CausalityError {
    fn from(err: CausalityGraphError) -> Self {
        CausalityError(format!("{err}"))
    }
}

impl From<UncertainError> for CausalityError {
    fn from(err: UncertainError) -> Self {
        CausalityError(format!("{err}"))
    }
}

impl From<CausalityError> for deep_causality_core::CausalityError {
    fn from(err: CausalityError) -> Self {
        deep_causality_core::CausalityError::new(deep_causality_core::CausalityErrorEnum::Custom(
            err.0,
        ))
    }
}
