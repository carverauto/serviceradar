/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub struct AdjustmentError(pub String);

impl AdjustmentError {
    pub fn new(field0: String) -> Self {
        Self(field0)
    }
}

impl Error for AdjustmentError {}

impl fmt::Display for AdjustmentError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "AdjustmentError: {}", self.0)
    }
}
