/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct BuildError(pub String);

impl BuildError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for BuildError {}

impl fmt::Display for BuildError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "BuildError: {}", self.0)
    }
}
