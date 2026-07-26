/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use super::TransactionError;

// No `source()`: the aborting status is flattened into code + message rather than kept as
// a nested error, so there is no source to return without a trait object.
impl core::error::Error for TransactionError {}
