/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use deep_causality_haft::LogAppend;
use std::collections::HashMap;

/// Status of an operation execution.
///
/// Used in [`ModificationLogEntry`] to indicate whether an operation
/// succeeded or failed.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum OpStatus {
    /// Operation completed successfully
    Success,
    /// Operation failed
    Failure,
}

/// A single entry in the modification audit trail.
///
/// Each entry captures detailed information about one operation execution,
/// including timing, target, status, and arbitrary metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModificationLogEntry {
    /// Timestamp in microseconds since UNIX epoch
    pub timestamp: u128,
    /// Human-readable name of the operation (e.g., "CreateCausaloid")
    pub operation_name: String,
    /// Identifier of the target entity (e.g., causaloid ID, context ID)
    pub target_id: String,
    /// Whether the operation succeeded or failed
    pub status: OpStatus,
    /// Descriptive message about the operation result
    pub message: String,
    /// Additional key-value metadata for detailed logging
    pub metadata: HashMap<String, String>,
}

impl ModificationLogEntry {
    /// Creates a new log entry without a timestamp.
    ///
    /// The timestamp will be automatically set when the entry is added to a
    /// `ModificationLog` via `add_entry()`.
    ///
    /// # Arguments
    ///
    /// * `operation_name` - Name of the operation (e.g., "CreateCausaloid")
    /// * `target_id` - ID of the target entity
    /// * `status` - Success or failure status
    /// * `message` - Descriptive message
    pub fn new(
        operation_name: impl Into<String>,
        target_id: impl Into<String>,
        status: OpStatus,
        message: impl Into<String>,
    ) -> Self {
        Self {
            timestamp: 0, // Will be set automatically by ModificationLog::add_entry
            operation_name: operation_name.into(),
            target_id: target_id.into(),
            status,
            message: message.into(),
            metadata: HashMap::new(),
        }
    }

    /// Creates a new log entry with metadata.
    ///
    /// # Arguments
    ///
    /// * `operation_name` - Name of the operation
    /// * `target_id` - ID of the target entity
    /// * `status` - Success or failure status
    /// * `message` - Descriptive message
    /// * `metadata` - Additional key-value metadata
    pub fn with_metadata(
        operation_name: impl Into<String>,
        target_id: impl Into<String>,
        status: OpStatus,
        message: impl Into<String>,
        metadata: HashMap<String, String>,
    ) -> Self {
        Self {
            timestamp: 0, // Will be set automatically by ModificationLog::add_entry
            operation_name: operation_name.into(),
            target_id: target_id.into(),
            status,
            message: message.into(),
            metadata,
        }
    }
}

/// Container for modification log entries, providing a complete audit trail.
///
/// This type serves as the "log" component (`L`) in the effect system's
/// arity-3 monad `GraphGeneratableEffectSafe<T, E, L>`.
#[derive(Default, Clone, Debug, PartialEq, Eq)]
pub struct ModificationLog {
    /// Ordered list of log entries
    pub entries: Vec<ModificationLogEntry>,
}

impl ModificationLog {
    /// Creates a new empty modification log.
    pub fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    /// Adds a new entry to the log with automatic timestamping.
    ///
    /// The timestamp is automatically set to the current time in microseconds
    /// since UNIX epoch, overriding any timestamp in the provided entry.
    pub fn add_entry(&mut self, mut entry: ModificationLogEntry) {
        // Automatically timestamp the entry
        entry.timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_micros();
        self.entries.push(entry);
    }

    /// Returns the number of entries in the log.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Returns true if the log contains no entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Returns an iterator over the log entries.
    pub fn iter(&self) -> impl Iterator<Item = &ModificationLogEntry> {
        self.entries.iter()
    }
}

impl LogAppend for ModificationLog {
    fn append(&mut self, other: &mut Self) {
        self.entries.append(&mut other.entries);
    }
}
