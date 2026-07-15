/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::CausalityError;
use crate::types::io::io_error;
use alloc::string::{String, ToString};
use alloc::vec::Vec;
use deep_causality_haft::IoAction;
use std::path::PathBuf;

/// A deferred action that reads a CSV file into rows of string fields. Performs no IO until `run`.
///
/// The parse is the inverse of [`WriteCsv`](crate::types::io::WriteCsv)'s rendering: the file is
/// split on `'\n'` (a trailing newline yields no empty final row) and each line on `','`. No quoting
/// or type conversion is applied; fields are returned verbatim.
pub struct ReadCsv {
    path: PathBuf,
}

impl IoAction for ReadCsv {
    type Output = Vec<Vec<String>>;
    type Error = CausalityError;

    #[inline]
    fn run(self) -> Result<Vec<Vec<String>>, CausalityError> {
        let contents = std::fs::read_to_string(&self.path).map_err(io_error)?;
        let rows = contents
            .lines()
            .map(|line| line.split(',').map(|f| f.to_string()).collect())
            .collect();
        Ok(rows)
    }
}

/// Describe reading the CSV file at `path` into rows of string fields (runs only at the edge).
#[inline]
pub fn read_csv(path: impl Into<PathBuf>) -> ReadCsv {
    ReadCsv { path: path.into() }
}
