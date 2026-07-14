/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub enum ModelGenerativeError {
    InvalidTrigger(String),
    InvalidTimeKind(String),
    InvalidDataReceivedError(String),
    InvalidManualInterventionError(String),
    InternalError(String),
    UserDefinedError(String),
}

impl Error for ModelGenerativeError {}

impl fmt::Display for ModelGenerativeError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            ModelGenerativeError::InvalidTrigger(msg) => write!(f, "Invalid trigger: {msg}"),
            ModelGenerativeError::InvalidTimeKind(msg) => write!(f, "Invalid time kind: {msg}"),
            ModelGenerativeError::InvalidDataReceivedError(msg) => {
                write!(f, "Invalid data received error: {msg}")
            }
            ModelGenerativeError::InvalidManualInterventionError(msg) => {
                write!(f, "Invalid manual intervention error: {msg}")
            }
            ModelGenerativeError::InternalError(msg) => write!(f, "Internal error: {msg}"),
            ModelGenerativeError::UserDefinedError(msg) => write!(f, "User defined error: {msg}"),
        }
    }
}
