/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct CausalGraphIndexError(pub String);

impl CausalGraphIndexError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for CausalGraphIndexError {}

impl fmt::Display for CausalGraphIndexError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "CausalGraphIndexError: {}", self.0)
    }
}
