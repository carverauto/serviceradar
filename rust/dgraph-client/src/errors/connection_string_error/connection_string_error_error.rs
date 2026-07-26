/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use super::ConnectionStringError;

// No `source()`: every variant is terminal structural detail about the connection string
// itself. Returning a source would require a trait object, which the static-dispatch rule
// in rust/README_RUST.md forbids.
impl core::error::Error for ConnectionStringError {}
