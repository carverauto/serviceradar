/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::UniformDistributionError;
use std::error::Error;

#[derive(Debug, PartialEq)]
pub enum RngError {
    OsRandomGenerator(String),
    InvalidRange(String),
}

impl Error for RngError {}

impl std::fmt::Display for RngError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            RngError::OsRandomGenerator(e) => write!(f, "OS random generator error: {}", e),
            RngError::InvalidRange(e) => write!(f, "Invalid range: {}", e),
        }
    }
}

impl From<UniformDistributionError> for RngError {
    fn from(e: UniformDistributionError) -> Self {
        RngError::InvalidRange(e.to_string())
    }
}
