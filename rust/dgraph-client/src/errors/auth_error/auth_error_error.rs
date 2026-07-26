/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use super::AuthError;

// No `source()`: originating failures are flattened into code + message fields so they
// survive without a boxed trait object.
impl core::error::Error for AuthError {}
