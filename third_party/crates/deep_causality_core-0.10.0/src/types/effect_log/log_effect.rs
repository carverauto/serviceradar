/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::types::effect_log::log_entry::LogEntry;
use core::fmt::{Debug, Display, Formatter};
use deep_causality_haft::{LogAddEntry, LogAppend, LogEffect, LogSize};

#[cfg(feature = "std")]
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(feature = "alloc")]
use alloc::string::{String, ToString};

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

/// Represents an encapsulated, timestamped log of causal evaluation events.
///
/// This struct provides a high-level API for logging and ensures that all
/// log entries are automatically timestamped. It hides the internal storage
/// details to provide a clean and robust interface.
/// An append-only audit log for causal operations.
///
/// `EffectLog` maintains a chronological record of all significant events, computations,
/// and interventions that occur during a causal process. This is crucial for:
/// *   **Explainability**: Tracing back *why* a certain result was reached.
/// *   **Auditability**: Providing a tamper-evident record of decisions suitable for compliance.
/// *   **Debugging**: Understanding the flow of complex graphs.
#[derive(Debug, Clone, Default, Eq)]
pub struct EffectLog {
    entries: Vec<LogEntry>,
}

/// Value equality of an `EffectLog` is its **message sequence**, ignoring entry timestamps.
///
/// Each entry is timestamped with `SystemTime::now()` at [`add_entry`](LogAddEntry::add_entry)
/// time (or `0` under `no_std`). Those timestamps are wall-clock *metadata*: two logically
/// identical logs built microseconds apart would otherwise never compare equal, which makes the
/// derived structural `==` non-deterministic and breaks value comparison of any
/// `CausalEffectPropagationProcess` carrying a non-empty log. Comparing by message content and
/// order keeps `==` a meaningful, reproducible equivalence. When the timestamps themselves are
/// the subject of comparison, use [`eq_with_timestamps`](Self::eq_with_timestamps).
impl PartialEq for EffectLog {
    fn eq(&self, other: &Self) -> bool {
        self.entries.len() == other.entries.len()
            && self
                .entries
                .iter()
                .zip(other.entries.iter())
                .all(|(a, b)| a.message() == b.message())
    }
}

impl EffectLog {
    /// Creates a new, empty log.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates a new, empty log with a specified capacity.
    pub fn with_capacity(capacity: usize) -> Self {
        Self {
            entries: Vec::with_capacity(capacity),
        }
    }

    /// Strict equality that also requires entry **timestamps** to match.
    ///
    /// The counterpart to the timestamp-agnostic [`PartialEq`] impl: returns `true` only when the
    /// two logs have the same messages *and* the same timestamps, in the same order. Use this when
    /// the temporal record is the subject of the comparison (e.g. auditing that two runs produced
    /// identically-timed entries); use `==` for ordinary value equality.
    pub fn eq_with_timestamps(&self, other: &Self) -> bool {
        self.entries == other.entries
    }
}

impl LogAddEntry for EffectLog {
    /// Adds a new timestamped entry to the log.
    ///
    /// # Arguments
    /// * `message` - The log message string slice.
    fn add_entry(&mut self, message: &str) {
        #[cfg(feature = "std")]
        let timestamp_micros = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros();

        #[cfg(not(feature = "std"))]
        let timestamp_micros = 0;
        // Add a non-std timestamp

        self.entries
            .push(LogEntry::new(timestamp_micros, message.to_string()))
    }
}

impl LogSize for EffectLog {
    /// Returns true if the log contains no entries.
    fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Returns the number of entries in the log.
    fn len(&self) -> usize {
        self.entries.len()
    }
}

// Marker trait for full log implementation
impl LogEffect for EffectLog {}

impl LogAppend for EffectLog {
    /// Merges another log's entries into this one. The entries from the other
    /// log are moved, and the other log will be empty after this operation.
    fn append(&mut self, other: &mut Self) {
        self.entries.append(&mut other.entries);
    }
}

/// Provides a clean way to create a log with a single initial entry.
/// e.g., `let log: CausalEffectLog = "Initial message".to_string().into();`
impl From<String> for EffectLog {
    fn from(message: String) -> Self {
        let mut log = Self::new();
        log.add_entry(&message);
        log
    }
}

/// Provides a clean way to create a log with a single initial entry from a string slice.
/// e.g., `let log: CausalEffectLog = "Initial message".into();`
impl From<&str> for EffectLog {
    fn from(message: &str) -> Self {
        let mut log = Self::new();
        log.add_entry(message);
        log
    }
}

impl Display for EffectLog {
    fn fmt(&self, f: &mut Formatter<'_>) -> core::fmt::Result {
        if self.entries.is_empty() {
            return write!(f, "EffectLog: (empty)");
        }

        writeln!(f, "EffectLog ({} entries):", self.entries.len())?;
        for entry in &self.entries {
            writeln!(f, "[{}", entry)?;
        }
        Ok(())
    }
}
