/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//!
//! Error type for assumption checking.
//!
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum AssumptionError {
    /// Error returned when verification is attempted on a model with no assumptions.
    NoAssumptionsDefined,
    ///Error returned when verification is attempted without data i.e. empty collection.
    NoDataToTestDefined,
    ///Error to capture the specific failed assumption
    AssumptionFailed(String),
    /// Wraps an error that occurred during the execution of an assumption function.
    EvaluationFailed(String),
}

impl Error for AssumptionError {}

impl fmt::Display for AssumptionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AssumptionError::NoAssumptionsDefined => {
                write!(f, "Model has no assumptions to verify")
            }
            AssumptionError::NoDataToTestDefined => {
                write!(f, "No Data to test provided")
            }
            AssumptionError::AssumptionFailed(a) => {
                write!(f, "Assumption failed: {a}")
            }
            AssumptionError::EvaluationFailed(msg) => {
                write!(f, "Failed to evaluate assumption: {msg}")
            }
        }
    }
}
