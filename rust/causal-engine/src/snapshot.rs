//! Context snapshot persistence for fast single-pod restart (task 1.7).
//!
//! TODO(1.7): serialize the `Context` + frozen `CausaloidGraph` to disk on a
//! cadence and on graceful shutdown; restore on start, then catch up from the
//! JetStream sequence/timestamp so restart is seconds, not a full cold rehydrate.

use crate::error::Result;

/// On-disk snapshot store.
#[derive(Default)]
pub struct SnapshotStore {
    // TODO(1.7): snapshot path + codec.
}

impl SnapshotStore {
    /// Construct a snapshot store. TODO(1.7): take the configured path.
    pub fn new() -> Self {
        Self::default()
    }

    /// Persist the current context/graph. TODO(1.7).
    pub fn save(&self) -> Result<()> {
        Ok(())
    }

    /// Restore from the latest snapshot if present. TODO(1.7).
    pub fn restore(&self) -> Result<()> {
        Ok(())
    }
}
