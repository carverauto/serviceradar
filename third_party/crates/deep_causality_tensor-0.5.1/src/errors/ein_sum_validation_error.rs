/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::error::Error;

/// Specific errors that can occur during EinSum AST validation or execution.
#[derive(Debug, Clone, PartialOrd, PartialEq)]
pub enum EinSumValidationError {
    /// Indicates an incorrect number of child nodes for an AST operation.
    InvalidNumberOfChildren { expected: usize, found: usize },
    /// Indicates an issue with the specified axes for an operation (e.g., out of bounds, duplicate).
    InvalidAxesSpecification { message: String },
    /// Indicates an operation that is not yet implemented or is used in an unsupported context.
    UnsupportedOperation { operation: String },
    /// Indicates a mismatch in tensor shapes that prevents an operation from proceeding.
    ShapeMismatch { message: String },
    /// Indicates that a tensor has an unexpected rank for a given operation.
    RankMismatch { expected: usize, found: usize },
}

impl std::fmt::Display for EinSumValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            EinSumValidationError::InvalidNumberOfChildren { expected, found } => {
                write!(
                    f,
                    "EinSumValidationError: Invalid number of children. Expected {}, found {}",
                    expected, found
                )
            }
            EinSumValidationError::InvalidAxesSpecification { message } => {
                write!(
                    f,
                    "EinSumValidationError: Invalid axes specification: {}",
                    message
                )
            }
            EinSumValidationError::UnsupportedOperation { operation } => {
                write!(
                    f,
                    "EinSumValidationError: Unsupported operation: {}",
                    operation
                )
            }
            EinSumValidationError::ShapeMismatch { message } => {
                write!(f, "EinSumValidationError: Shape mismatch: {}", message)
            }
            EinSumValidationError::RankMismatch { expected, found } => {
                write!(
                    f,
                    "EinSumValidationError: Rank mismatch. Expected {}, found {}",
                    expected, found
                )
            }
        }
    }
}

impl Error for EinSumValidationError {}
