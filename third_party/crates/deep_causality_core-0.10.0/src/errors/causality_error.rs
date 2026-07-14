/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use alloc::string::String;
use core::fmt::{Display, Formatter};

/// The standard error type for DeepCausality operations.
///
/// This wrapper struct ensures that all errors within the system share a common type,
/// facilitating uniform error propagation and handling within the monadic structures.
#[derive(Debug, Default, Clone, PartialEq, Eq, Hash)]
pub struct CausalityError(pub CausalityErrorEnum);

impl CausalityError {
    /// Creates a new `CausalityError` from the specific error variant.
    pub const fn new(error_enum: CausalityErrorEnum) -> Self {
        Self(error_enum)
    }
}

#[cfg(feature = "std")]
impl std::error::Error for CausalityError {}

impl Display for CausalityError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        // Delegate to the debug representation of the inner enum.
        write!(f, "{:?}", self.0)
    }
}

/// Detailed variants of potential errors in the system.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Default)]
pub enum CausalityErrorEnum {
    // Generic Errors
    /// An error occurred that doesn't fit into other categories.
    #[default]
    Unspecified,
    /// An unreachable code path was executed; indicates a bug in the library or logic.
    InternalLogicError,
    /// Failed to convert a value to the expected concrete type.
    TypeConversionError,
    /// A required value was expected but `None` was found.
    ValueNotAvailable,

    // Graph Execution Errors
    /// The execution exceeded the maximum allowed steps (infinite loop protection).
    MaxStepsExceeded,

    // Migration / Legacy Support Errors
    /// A user-defined custom error message.
    Custom(String),
    /// Error related to executing an action.
    ActionError(String),
    /// Error related to deontic logic constraints.
    DeonticError(String),
    /// Error related to the internal model state.
    ModelError(String),
}
