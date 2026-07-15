/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalityError;
use crate::types::io::io_error;
use alloc::string::String;
use deep_causality_haft::IoAction;
use std::path::PathBuf;

/// A deferred action that writes `contents` to a file, creating or truncating it. Performs no IO
/// until `run`. The bytes written are exactly `contents`.
pub struct WriteText {
    path: PathBuf,
    contents: String,
}

impl IoAction for WriteText {
    type Output = ();
    type Error = CausalityError;

    #[inline]
    fn run(self) -> Result<(), CausalityError> {
        std::fs::write(&self.path, self.contents.as_bytes()).map_err(io_error)
    }
}

/// Describe writing `contents` to the file at `path` (runs only at the edge).
#[inline]
pub fn write_text(path: impl Into<PathBuf>, contents: impl Into<String>) -> WriteText {
    WriteText {
        path: path.into(),
        contents: contents.into(),
    }
}
