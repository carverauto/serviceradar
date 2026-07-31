/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

#![forbid(unsafe_code)]

use std::error::Error;
use std::fmt;

pub mod graph_error;

#[derive(Debug)]
pub struct UltraGraphError(pub String);

impl UltraGraphError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for UltraGraphError {}

impl fmt::Display for UltraGraphError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "UltraGraphError: {}", self.0)
    }
}
