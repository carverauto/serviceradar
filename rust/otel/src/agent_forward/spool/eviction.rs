//! Spool space reclamation: release-on-ack and budget/age eviction.
//!
//! Releasing a fully-acked sealed segment is routine cleanup (no counters
//! move). Evicting a segment that still holds unacked frames is data loss by
//! policy (`max_bytes`/`max_age`), so every evicted unacked record is counted
//! per signal and surfaced through metrics and `TelemetryCounters.dropped`.

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use addon_sdk::pb::{OtlpRelayFrame, TelemetryPayloadKind};
use anyhow::{Context, Result};
use log::{debug, warn};
use prost::Message;

use super::Inner;
use super::segments::MAX_RECORD_BYTES;

/// Cumulative per-signal counts of records evicted from the spool before
/// they were acked (oldest-first overflow / age eviction). Wired into the
/// prometheus counters ([`crate::metrics::record_spool_evicted`]) and into
/// `TelemetryCounters.dropped` on outgoing batches.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct EvictionCounters {
    pub traces: u64,
    pub logs: u64,
    pub metrics: u64,
    pub derived_metrics: u64,
    pub other: u64,
}

impl EvictionCounters {
    pub fn total(&self) -> u64 {
        self.traces + self.logs + self.metrics + self.derived_metrics + self.other
    }

    fn bump_kind(&mut self, kind: i32) {
        match TelemetryPayloadKind::try_from(kind) {
            Ok(TelemetryPayloadKind::OtlpTraces) => self.traces += 1,
            Ok(TelemetryPayloadKind::OtlpLogs) => self.logs += 1,
            Ok(TelemetryPayloadKind::OtlpMetrics) => self.metrics += 1,
            Ok(TelemetryPayloadKind::OtlpDerivedMetric) => self.derived_metrics += 1,
            _ => self.other += 1,
        }
    }

    fn add(&mut self, other: &EvictionCounters) {
        self.traces += other.traces;
        self.logs += other.logs;
        self.metrics += other.metrics;
        self.derived_metrics += other.derived_metrics;
        self.other += other.other;
    }
}

impl Inner {
    /// Deletes sealed segments whose every frame is acked (NOT an eviction;
    /// no counters move).
    pub(super) fn release_acked(&mut self) -> Result<()> {
        while self
            .sealed
            .front()
            .is_some_and(|s| s.last_relay_id <= self.watermark)
        {
            let seg = self.sealed.pop_front().expect("checked front() above");
            debug!(
                "releasing fully-acked spool segment {} (relay_ids {}..={})",
                seg.path.display(),
                seg.first_relay_id,
                seg.last_relay_id
            );
            fs::remove_file(&seg.path)
                .with_context(|| format!("failed to remove {}", seg.path.display()))?;
        }
        Ok(())
    }

    /// Oldest-first eviction: age bound first, then the byte budget. Only
    /// sealed segments are evicted, so the spool can overshoot `max_bytes`
    /// by at most one active segment.
    pub(super) fn enforce_limits(&mut self) -> Result<()> {
        if let Some(max_age) = self.config.max_age {
            while self.sealed.front().is_some_and(|s| {
                s.sealed_at
                    .elapsed()
                    .map(|age| age > max_age)
                    .unwrap_or(false)
            }) {
                self.evict_front("max_age exceeded")?;
            }
        }
        while self.total_bytes() > self.config.max_bytes && !self.sealed.is_empty() {
            self.evict_front("max_bytes exceeded")?;
        }
        Ok(())
    }

    pub(super) fn evict_front(&mut self, reason: &str) -> Result<()> {
        let seg = self.sealed.pop_front().expect("caller checked non-empty");
        let counts = count_unacked_records(&seg.path, self.watermark);
        if counts.total() > 0 {
            warn!(
                "evicting relay spool segment {} with {} unacked record(s) ({reason})",
                seg.path.display(),
                counts.total()
            );
        }
        crate::metrics::record_spool_evicted("traces", counts.traces);
        crate::metrics::record_spool_evicted("logs", counts.logs);
        crate::metrics::record_spool_evicted("metrics", counts.metrics);
        crate::metrics::record_spool_evicted("derived_metrics", counts.derived_metrics);
        crate::metrics::record_spool_evicted("other", counts.other);
        self.evicted.add(&counts);
        fs::remove_file(&seg.path)
            .with_context(|| format!("failed to evict {}", seg.path.display()))?;
        Ok(())
    }
}

/// Best-effort per-signal count of unacked records in a segment about to be
/// evicted (the segment was validated at write/recovery time).
fn count_unacked_records(path: &Path, watermark: u64) -> EvictionCounters {
    let mut counters = EvictionCounters::default();
    let Ok(mut file) = File::open(path) else {
        return counters;
    };
    let Ok(metadata) = file.metadata() else {
        return counters;
    };
    let file_len = metadata.len();
    let mut offset = 0u64;
    while offset + 4 <= file_len {
        if file.seek(SeekFrom::Start(offset)).is_err() {
            break;
        }
        let mut len_buf = [0u8; 4];
        if file.read_exact(&mut len_buf).is_err() {
            break;
        }
        let len = u64::from(u32::from_le_bytes(len_buf));
        if len == 0 || len > MAX_RECORD_BYTES || offset + 4 + len > file_len {
            break;
        }
        let mut buf = vec![0u8; len as usize];
        if file.read_exact(&mut buf).is_err() {
            break;
        }
        if let Ok(frame) = OtlpRelayFrame::decode(buf.as_slice())
            && frame.relay_id > watermark
            && let Some(batch) = &frame.batch
        {
            for record in &batch.records {
                counters.bump_kind(record.payload_kind);
            }
        }
        offset += 4 + len;
    }
    counters
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use addon_sdk::pb::TelemetryPayloadKind;

    use crate::agent_forward::spool::Spool;
    use crate::agent_forward::spool::testutil::{segment_count, small_config, test_batch};

    #[test]
    fn watermark_releases_fully_acked_segments() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        // ~100 bytes/frame against 512-byte segments: several rotations.
        let mut last = 0;
        for _ in 0..30 {
            last = spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![7; 64]))
                .unwrap();
        }
        let before = segment_count(dir.path());
        assert!(before > 2, "expected multiple segments, got {before}");

        spool.advance_watermark(last).unwrap();
        let after = segment_count(dir.path());
        assert!(
            after <= 1,
            "fully-acked sealed segments must be released (left {after})"
        );
        assert_eq!(spool.stats().evicted.total(), 0, "release is not eviction");
    }

    #[test]
    fn eviction_counts_unacked_records_per_signal() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = small_config(dir.path());
        config.max_bytes = 1024; // force oldest-first eviction quickly

        let spool = Arc::new(Spool::open(config).unwrap());
        for _ in 0..10 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![1; 64]))
                .unwrap();
        }
        for _ in 0..10 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![2; 64]))
                .unwrap();
        }

        let stats = spool.stats();
        assert!(
            stats.total_bytes <= 1024 + 512,
            "bounded by max_bytes + one segment, got {}",
            stats.total_bytes
        );
        assert!(stats.evicted.traces > 0, "oldest (trace) frames evicted");
        assert_eq!(
            stats.evicted.total(),
            stats.evicted.traces + stats.evicted.logs,
            "only trace/log signals were appended"
        );

        // The reader must skip evicted ids and yield surviving frames only.
        let mut reader = spool.reader();
        let frame = reader.try_next().unwrap().expect("surviving frame");
        assert!(frame.relay_id > stats.evicted.total());
    }

    #[test]
    fn eviction_is_stamped_into_outgoing_counters() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = small_config(dir.path());
        config.max_bytes = 1024;

        let spool = Arc::new(Spool::open(config).unwrap());
        for _ in 0..20 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpMetrics, vec![3; 64]))
                .unwrap();
        }
        let evicted = spool.stats().evicted.total();
        assert!(evicted > 0);

        let id = spool
            .append_batch(test_batch(TelemetryPayloadKind::OtlpMetrics, vec![4; 16]))
            .unwrap();
        let mut reader = spool.reader();
        let mut found = None;
        while let Some(frame) = reader.try_next().unwrap() {
            if frame.relay_id == id {
                found = frame.batch;
                break;
            }
        }
        let counters = found
            .expect("appended frame readable")
            .counters
            .expect("counters stamped");
        assert!(
            counters.dropped >= evicted,
            "TelemetryCounters.dropped carries cumulative evictions"
        );
        assert!(counters.queue_depth > 0);
    }

    #[test]
    fn max_age_evicts_old_sealed_segments() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = small_config(dir.path());
        config.max_age = Some(Duration::from_secs(0));

        let spool = Arc::new(Spool::open(config).unwrap());
        for _ in 0..10 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![1; 64]))
                .unwrap();
        }
        // With max_age = 0 every sealed segment is expired as soon as the
        // next append runs enforce_limits.
        assert!(spool.stats().evicted.total() > 0);
        assert!(segment_count(dir.path()) <= 1, "only the active remains");
    }
}
