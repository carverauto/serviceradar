/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use core::fmt::{Display, Formatter};

/// Errors surfaced by plan construction and execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FftError {
    /// The requested transform length (or a shape axis) is zero.
    InvalidLength(usize),
    /// A buffer length does not match what the plan requires.
    LengthMismatch { expected: usize, got: usize },
    /// The caller-provided scratch buffer is too small.
    ScratchTooSmall { required: usize, got: usize },
}

impl Display for FftError {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        match self {
            FftError::InvalidLength(n) => {
                write!(f, "FftError: invalid transform length {n}")
            }
            FftError::LengthMismatch { expected, got } => {
                write!(
                    f,
                    "FftError: buffer length mismatch, expected {expected}, got {got}"
                )
            }
            FftError::ScratchTooSmall { required, got } => {
                write!(
                    f,
                    "FftError: scratch buffer too small, required {required}, got {got}"
                )
            }
        }
    }
}

impl core::error::Error for FftError {}
