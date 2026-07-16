/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::{CausaloidId, ContextId, ContextoidId};
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub enum ModelValidationError {
    // Causaloid Errors
    MissingCreateCausaloid,
    DuplicateCausaloidID { id: CausaloidId },
    TargetCausaloidNotFound { id: CausaloidId },

    // Context Errors
    BaseContextNotFound,
    DuplicateContextId { id: ContextId },
    TargetContextNotFound { id: ContextId },
    DuplicateExtraContextId { id: u64 },

    // Contextoid Errors
    TargetContextoidNotFound { id: ContextoidId },
    DuplicateContextoidId { id: ContextoidId },
    AddContextoidError { err: String },

    // General Errors
    UnsupportedOperation { operation: String },
    UpdateNodeError { err: String },
    RemoveNodeError { err: String },
    InterpreterError { reason: String },
}

impl Error for ModelValidationError {}

impl fmt::Display for ModelValidationError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ModelValidationError::MissingCreateCausaloid => {
                write!(
                    f,
                    "The generative output is missing the mandatory Causaloid creation command."
                )
            }
            ModelValidationError::DuplicateCausaloidID { id } => {
                write!(f, "Duplicate Causaloid ID found: {id}")
            }
            ModelValidationError::TargetCausaloidNotFound { id } => {
                write!(f, "Target Causaloid with ID {id} not found")
            }
            ModelValidationError::BaseContextNotFound => {
                write!(
                    f,
                    "Cannot perform operation because the base context has not been created"
                )
            }
            ModelValidationError::DuplicateContextId { id } => {
                write!(f, "Duplicate Context ID found: {id}")
            }
            ModelValidationError::TargetContextNotFound { id } => {
                write!(f, "Target Context with ID {id} not found")
            }
            ModelValidationError::DuplicateExtraContextId { id } => {
                write!(f, "Duplicate Extra Context ID found: {id}")
            }

            ModelValidationError::TargetContextoidNotFound { id } => {
                write!(f, "Target Contextoid with ID {id} not found")
            }

            ModelValidationError::DuplicateContextoidId { id } => {
                write!(f, "Duplicate Contextoid ID found: {id}")
            }

            ModelValidationError::UnsupportedOperation { operation } => {
                write!(f, "Unsupported operation: {operation}")
            }
            ModelValidationError::UpdateNodeError { err } => {
                write!(f, "Error updating node: {err}")
            }
            ModelValidationError::RemoveNodeError { err } => {
                write!(f, "Error removing node: {err}")
            }
            ModelValidationError::InterpreterError { reason } => {
                write!(f, "Interpreter error: {reason}")
            }
            ModelValidationError::AddContextoidError { err } => {
                write!(f, "Error adding Contextoid: {err}")
            }
        }
    }
}
