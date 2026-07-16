/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct ContextIndexError(pub String);

impl ContextIndexError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for ContextIndexError {}

impl fmt::Display for ContextIndexError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "ContextIndexError: {}", self.0)
    }
}
