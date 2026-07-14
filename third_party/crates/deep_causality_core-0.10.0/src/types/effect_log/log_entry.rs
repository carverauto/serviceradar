/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */
#[cfg(feature = "alloc")]
use alloc::format;
#[cfg(feature = "alloc")]
use alloc::string::String;
use core::fmt::Display;

// Internal struct, not exposed in the public API.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(in crate::types) struct LogEntry {
    timestamp_ms: u128,
    message: String,
}

impl LogEntry {
    pub const fn new(timestamp_ms: u128, message: String) -> Self {
        Self {
            timestamp_ms,
            message,
        }
    }
}

impl LogEntry {
    pub const fn timestamp_ms(&self) -> u128 {
        self.timestamp_ms
    }

    pub fn message(&self) -> &str {
        &self.message
    }
}

impl Display for LogEntry {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        format!("[{:0>6}] {}", self.timestamp_ms(), self.message()).fmt(f)
    }
}
