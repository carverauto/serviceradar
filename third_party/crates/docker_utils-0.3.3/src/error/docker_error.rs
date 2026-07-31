/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug, Clone)]
pub struct DockerError(pub String);

impl DockerError {
    #[must_use]
    pub fn new(field0: &str) -> Self {
        Self(field0.to_string())
    }
}

impl From<&str> for DockerError {
    fn from(field0: &str) -> Self {
        Self(field0.to_string())
    }
}

impl From<String> for DockerError {
    fn from(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for DockerError {}

impl fmt::Display for DockerError {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "DockerError: {}", self.0)
    }
}
