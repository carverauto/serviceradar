/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#[cfg(feature = "alloc")]
use alloc::string::String;

use core::fmt;

/// Errors that can occur during metric operations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MetricError {
    /// Sign convention mismatch (e.g., expected East Coast, got West Coast)
    SignConventionMismatch(String),
    /// Invalid dimension (e.g., zero or exceeds bitmask capacity)
    InvalidDimension(String),
    /// Metric validation failed
    ValidationFailed(String),
    /// Conversion not possible
    ConversionError(String),
}

impl MetricError {
    /// Creates a SignConventionMismatch error.
    pub fn sign_convention_mismatch(msg: impl Into<String>) -> Self {
        Self::SignConventionMismatch(msg.into())
    }

    /// Creates an InvalidDimension error.
    pub fn invalid_dimension(msg: impl Into<String>) -> Self {
        Self::InvalidDimension(msg.into())
    }

    /// Creates a ValidationFailed error.
    pub fn validation_failed(msg: impl Into<String>) -> Self {
        Self::ValidationFailed(msg.into())
    }

    /// Creates a ConversionError.
    pub fn conversion_error(msg: impl Into<String>) -> Self {
        Self::ConversionError(msg.into())
    }
}

impl fmt::Display for MetricError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MetricError::SignConventionMismatch(msg) => {
                write!(f, "Sign convention mismatch: {}", msg)
            }
            MetricError::InvalidDimension(msg) => {
                write!(f, "Invalid dimension: {}", msg)
            }
            MetricError::ValidationFailed(msg) => {
                write!(f, "Metric validation failed: {}", msg)
            }
            MetricError::ConversionError(msg) => {
                write!(f, "Conversion error: {}", msg)
            }
        }
    }
}

#[cfg(feature = "std")]
impl std::error::Error for MetricError {}
