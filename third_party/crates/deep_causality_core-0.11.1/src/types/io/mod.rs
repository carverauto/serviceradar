/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

//! File specialization of the IO effect: concrete [`IoAction`]s that read and write files.
//!
//! These are the `std`-only file actions of the `Io` abstraction defined in `deep_causality_haft`.
//! Each is a deferred description — constructing one performs **no** side effect — and each fixes
//! `Error = CausalityError` (an IO failure becomes [`CausalityErrorEnum::IoError`]), so an IO chain
//! short-circuits like the rest of the causal monad and composes with `CausalFlow`.
//!
//! [`IoAction`]: deep_causality_haft::IoAction
//! [`CausalityErrorEnum::IoError`]: crate::CausalityErrorEnum::IoError

mod read_csv;
mod read_text;
mod write_csv;
mod write_text;

pub use read_csv::{ReadCsv, read_csv};
pub use read_text::{ReadText, read_text};
pub use write_csv::{WriteCsv, write_csv};
pub use write_text::{WriteText, write_text};

use crate::{CausalityError, CausalityErrorEnum};
use alloc::string::ToString;

/// Maps a `std::io::Error` into a `CausalityError::IoError`, used by every file action's `run`.
#[inline]
pub(crate) fn io_error(err: std::io::Error) -> CausalityError {
    CausalityError::new(CausalityErrorEnum::IoError(err.to_string()))
}
