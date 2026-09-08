//! Context snapshot persistence for fast/resilient restart (task 1.7).
//!
//! The hydrator persists the shared `Context` to disk after each `EmbeddedSrql`
//! refresh and restores it on start. On a restart (or a transient CNPG blip at
//! boot) the engine can serve the last-known `Context` immediately instead of a
//! full cold rehydrate; the periodic refresh + live `signals.state.>` deltas then
//! bring it current.

use std::path::PathBuf;

use crate::domain_model::Context;
use crate::error::{CorrelationEngineError, Result};

/// On-disk JSON snapshot of the `Context`.
pub struct SnapshotStore {
    path: PathBuf,
}

impl SnapshotStore {
    /// Construct a snapshot store at `path`.
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    /// Persist the `Context` atomically (write to a temp file, then rename).
    pub fn save(&self, context: &Context) -> Result<()> {
        let json = serde_json::to_vec(context)
            .map_err(|e| CorrelationEngineError::Snapshot(format!("encode: {e}")))?;

        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| {
                CorrelationEngineError::Snapshot(format!("mkdir {}: {e}", dir.display()))
            })?;
        }

        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, &json).map_err(|e| {
            CorrelationEngineError::Snapshot(format!("write {}: {e}", tmp.display()))
        })?;
        std::fs::rename(&tmp, &self.path).map_err(|e| {
            CorrelationEngineError::Snapshot(format!("rename {}: {e}", self.path.display()))
        })?;
        Ok(())
    }

    /// Load the snapshot if present. Returns `Ok(None)` when no snapshot exists.
    pub fn load(&self) -> Result<Option<Context>> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map(Some)
                .map_err(|e| CorrelationEngineError::Snapshot(format!("decode: {e}"))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(CorrelationEngineError::Snapshot(format!(
                "read {}: {e}",
                self.path.display()
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain_model::{Context, Device};

    #[test]
    fn save_then_load_round_trips() {
        let dir = std::env::temp_dir().join(format!("causal-engine-snap-{}", std::process::id()));
        let path = dir.join("snapshot.json");
        let store = SnapshotStore::new(path.clone());

        assert!(
            store.load().expect("load").is_none(),
            "absent snapshot -> None"
        );

        let ctx = Context {
            devices: vec![Device {
                uid: "sr:device:abc".to_string(),
                is_available: Some(true),
                is_managed: Some(false),
                risk_score: Some(72),
                ..Default::default()
            }],
            ..Default::default()
        };
        store.save(&ctx).expect("save");

        let loaded = store.load().expect("load").expect("present");
        assert_eq!(loaded.devices.len(), 1);
        assert_eq!(loaded.devices[0].uid, "sr:device:abc");
        assert_eq!(loaded.devices[0].risk_score, Some(72));

        let _ = std::fs::remove_dir_all(&dir);
    }
}
