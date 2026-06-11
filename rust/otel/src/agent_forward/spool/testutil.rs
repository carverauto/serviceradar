//! Shared fixtures for the spool unit tests.

use std::fs;
use std::path::{Path, PathBuf};

use addon_sdk::pb::{TelemetryBatch, TelemetryPayloadKind, TelemetryRecord, TelemetrySource};

use super::{DEFAULT_SPOOL_MAX_BYTES, DiskFree, SpoolConfig};

pub(super) fn test_batch(kind: TelemetryPayloadKind, payload: Vec<u8>) -> TelemetryBatch {
    TelemetryBatch {
        source: Some(TelemetrySource {
            source_type: "otel-collector".to_string(),
            source_instance: "test".to_string(),
            metadata: Default::default(),
        }),
        records: vec![TelemetryRecord {
            event_id: "test-event".to_string(),
            observed_time_unix_nano: 1,
            event_time_unix_nano: 0,
            payload_kind: kind as i32,
            payload,
            metadata: Default::default(),
        }],
        counters: None,
    }
}

pub(super) fn small_config(dir: &Path) -> SpoolConfig {
    SpoolConfig {
        dir: dir.to_path_buf(),
        max_bytes: DEFAULT_SPOOL_MAX_BYTES,
        max_age: None,
        segment_max_bytes: 512, // tiny segments so tests rotate quickly
        min_free_disk_bytes: 0, // floor disabled unless a test opts in
    }
}

/// Deterministic free-disk fake: a fixed-capacity volume whose free space is
/// `capacity` minus the bytes currently inside the probed directory, so
/// evicting a segment really frees space (no statvfs involved).
pub(super) struct FakeVolume {
    pub(super) capacity: u64,
}

impl DiskFree for FakeVolume {
    fn available_bytes(&self, path: &Path) -> Option<u64> {
        let used: u64 = fs::read_dir(path)
            .ok()?
            .filter_map(|entry| entry.ok())
            .filter_map(|entry| entry.metadata().ok())
            .map(|meta| meta.len())
            .sum();
        Some(self.capacity.saturating_sub(used))
    }
}

pub(super) fn segment_count(dir: &Path) -> usize {
    fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().is_some_and(|ext| ext == "seg"))
        .count()
}

pub(super) fn newest_segment(dir: &Path) -> PathBuf {
    let mut segs: Vec<PathBuf> = fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|ext| ext == "seg"))
        .collect();
    segs.sort();
    segs.pop().expect("at least one segment")
}
