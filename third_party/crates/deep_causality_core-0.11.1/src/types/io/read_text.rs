/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalityError;
use crate::types::io::io_error;
use alloc::string::String;
use deep_causality_haft::IoAction;
use std::path::PathBuf;

/// A deferred action that reads an entire file to a `String`. Performs no IO until `run`.
pub struct ReadText {
    path: PathBuf,
}

impl IoAction for ReadText {
    type Output = String;
    type Error = CausalityError;

    #[inline]
    fn run(self) -> Result<String, CausalityError> {
        std::fs::read_to_string(&self.path).map_err(io_error)
    }
}

/// Describe reading the file at `path` to a `String` (runs only at the edge).
#[inline]
pub fn read_text(path: impl Into<PathBuf>) -> ReadText {
    ReadText { path: path.into() }
}
