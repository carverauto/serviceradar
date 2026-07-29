/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) "2025" . The buildutils Authors and Contributors. All Rights Reserved.
 */

mod api;
mod container;
mod docker;
mod error;
/// Public only so that the test suite under `tests/` can reach it, and hidden from the
/// documentation because it is not part of the supported API.
#[doc(hidden)]
pub mod utils_test;

// Re-exports
pub use crate::container::container_config::*;
pub use crate::container::container_diagnostics::*;
pub use crate::docker::DockerUtil;
pub use crate::error::DockerError;
// Re-export of direct dependencies
pub use wait_utils::*;
