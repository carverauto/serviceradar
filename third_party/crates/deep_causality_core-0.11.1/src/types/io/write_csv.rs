/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalityError;
use crate::types::io::io_error;
use alloc::string::String;
use alloc::vec::Vec;
use deep_causality_haft::IoAction;
use std::path::PathBuf;

/// A deferred action that writes a CSV file from pre-rendered fields. Performs no IO until `run`.
///
/// The bytes are fully caller-determined: the header line (`','`-joined fields) is written first,
/// then each row (`','`-joined fields); every line, including the last, is `'\n'`-terminated. Because
/// the fields are already strings, the exact output can reproduce any prior `println!`/`writeln!`
/// stream byte-for-byte.
pub struct WriteCsv {
    path: PathBuf,
    header: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl WriteCsv {
    /// Renders the file contents the action will write. Separated from `run` so it is unit-testable
    /// without touching the filesystem.
    fn render(&self) -> String {
        let mut out = String::new();
        out.push_str(&self.header.join(","));
        out.push('\n');
        for row in &self.rows {
            out.push_str(&row.join(","));
            out.push('\n');
        }
        out
    }
}

impl IoAction for WriteCsv {
    type Output = ();
    type Error = CausalityError;

    #[inline]
    fn run(self) -> Result<(), CausalityError> {
        std::fs::write(&self.path, self.render().as_bytes()).map_err(io_error)
    }
}

/// Describe writing a CSV file at `path` from a `header` and pre-rendered `rows` (runs only at the
/// edge). Each field is written verbatim; no quoting or escaping is applied.
#[inline]
pub fn write_csv(
    path: impl Into<PathBuf>,
    header: Vec<String>,
    rows: Vec<Vec<String>>,
) -> WriteCsv {
    WriteCsv {
        path: path.into(),
        header,
        rows,
    }
}
