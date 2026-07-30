/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use crate::EinSumValidationError;
use std::error::Error;

/// Errors that can occur during tensor operations.
#[derive(Debug, Clone, PartialOrd, PartialEq)]
pub enum CausalTensorError {
    ShapeMismatch,
    DimensionMismatch,
    DivisionByZero,
    AxisOutOfBounds,
    EmptyTensor,
    InvalidOperation,
    UnorderableValue,
    InvalidParameter(String),
    SingularMatrix,   // Added for matrix inversion errors
    IndexOutOfBounds, // Added for out-of-bounds access errors
    /// Adjacent tensor-train cores disagree on the shared bond dimension.
    BondDimensionMismatch,
    /// A tensor-train operation required a canonical gauge the train was not in.
    NotCanonical,
    /// A dense materialization would exceed the element-count guard.
    RankExceeded,
    /// A TT-cross oracle returned a non-finite value during sampling.
    CrossSampleFailure,
    /// An ALS/DMRG sweep did not reach the residual target within the sweep budget.
    SweepDidNotConverge,
    /// Encapsulates errors specific to EinSum AST validation and execution.
    EinSumError(EinSumValidationError),
}

impl Error for CausalTensorError {}

impl std::fmt::Display for CausalTensorError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            CausalTensorError::ShapeMismatch => {
                write!(f, "CausalTensorError: Shape mismatch error")
            }
            CausalTensorError::DimensionMismatch => {
                write!(f, "CausalTensorError: Dimension mismatch error")
            }
            CausalTensorError::AxisOutOfBounds => {
                write!(f, "CausalTensorError: Axis out of bounds error")
            }
            CausalTensorError::EmptyTensor => write!(f, "CausalTensorError: Empty tensor error"),
            CausalTensorError::InvalidOperation => {
                write!(f, "CausalTensorError: Invalid operation error")
            }
            CausalTensorError::UnorderableValue => {
                write!(f, "CausalTensorError: Unorderable value encountered")
            }
            CausalTensorError::InvalidParameter(s) => {
                write!(f, "CausalTensorError: Invalid parameter: {}", s)
            }
            CausalTensorError::DivisionByZero => {
                write!(f, "CausalTensorError: Division by zero error")
            }
            CausalTensorError::SingularMatrix => {
                write!(
                    f,
                    "CausalTensorError: Singular matrix error - inverse does not exist"
                )
            }
            CausalTensorError::IndexOutOfBounds => {
                write!(f, "CausalTensorError: Index out of bounds error")
            }
            CausalTensorError::BondDimensionMismatch => {
                write!(f, "CausalTensorError: Tensor-train bond dimension mismatch")
            }
            CausalTensorError::NotCanonical => {
                write!(
                    f,
                    "CausalTensorError: Tensor train is not in the required canonical form"
                )
            }
            CausalTensorError::RankExceeded => {
                write!(
                    f,
                    "CausalTensorError: Dense materialization exceeds the element-count guard"
                )
            }
            CausalTensorError::CrossSampleFailure => {
                write!(
                    f,
                    "CausalTensorError: TT-cross oracle returned a non-finite value"
                )
            }
            CausalTensorError::SweepDidNotConverge => {
                write!(
                    f,
                    "CausalTensorError: ALS/DMRG sweep did not converge within the sweep budget"
                )
            }
            CausalTensorError::EinSumError(e) => {
                write!(f, "CausalTensorError: EinSumError: {}", e)
            }
        }
    }
}
