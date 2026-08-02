/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::TopologyError;

/// Error type for link
///
/// variable operations.
#[derive(Debug, Clone, PartialEq)]
pub enum LinkVariableError {
    /// Matrix shape mismatch for operation.
    ShapeMismatch {
        expected: Vec<usize>,
        got: Vec<usize>,
    },
    /// Tensor creation failed.
    TensorCreation(String),
    /// Matrix is singular (determinant = 0).
    SingularMatrix,
    /// Invalid matrix dimension.
    InvalidDimension(usize),
    /// Numerical error during computation.
    NumericalError(String),
}

impl std::fmt::Display for LinkVariableError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ShapeMismatch { expected, got } => {
                write!(f, "Shape mismatch: expected {:?}, got {:?}", expected, got)
            }
            Self::TensorCreation(msg) => write!(f, "Tensor creation failed: {}", msg),
            Self::SingularMatrix => write!(f, "Matrix is singular"),
            Self::InvalidDimension(n) => write!(f, "Invalid matrix dimension: {}", n),
            Self::NumericalError(msg) => write!(f, "Numerical error: {}", msg),
        }
    }
}

impl std::error::Error for LinkVariableError {}

impl From<LinkVariableError> for TopologyError {
    fn from(e: LinkVariableError) -> Self {
        TopologyError::LatticeGaugeError(e.to_string())
    }
}
