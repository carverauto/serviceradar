/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct IndexError(pub String);

impl IndexError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for IndexError {}

impl fmt::Display for IndexError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "IndexError: {}", self.0)
    }
}

impl From<String> for IndexError {
    fn from(s: String) -> Self {
        IndexError(s)
    }
}

impl From<&str> for IndexError {
    fn from(s: &str) -> Self {
        IndexError(s.to_string())
    }
}
