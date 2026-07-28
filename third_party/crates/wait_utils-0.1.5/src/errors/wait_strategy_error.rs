/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug, Clone)]
pub struct WaitStrategyError(pub String);

impl WaitStrategyError {
    #[must_use]
    pub fn new(field0: &str) -> Self {
        Self(field0.to_string())
    }
}

impl From<&str> for WaitStrategyError {
    fn from(field0: &str) -> Self {
        Self(field0.to_string())
    }
}

impl From<String> for WaitStrategyError {
    fn from(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for WaitStrategyError {}

impl fmt::Display for WaitStrategyError {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "WaitStrategyError: {}", self.0)
    }
}
