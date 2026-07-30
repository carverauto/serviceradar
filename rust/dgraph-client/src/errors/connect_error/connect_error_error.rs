/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use super::ConnectError;

// No `source()`: transport and TLS failures are rendered to text at construction, so the
// error stays `Clone + Eq + Hash` and needs no trait object.
impl core::error::Error for ConnectError {}
