//! Durable segment spool backing the agent-forward output backend.
//!
//! The spool is the durability owner for edge telemetry between "OTLP client
//! got OK" and "agent acked the frame after gateway acceptance" (edge-relay
//! plan D-d/D-f). It is an append-only, length-prefixed log of encoded
//! [`OtlpRelayFrame`] messages split into fixed-size segments:
//!
//! ```text
//! <spool_dir>/
//!   relay.meta                      # magic + ack watermark + relay-id ceiling
//!   00000000000000000001.seg        # [u32 LE len][OtlpRelayFrame bytes]...
//!   00000000000000000042.seg        # file name = first relay_id in segment
//! ```
//!
//! Durability/fsync contract (matches the plan):
//! - segment data + meta are fsynced on **segment rotation** (8 MiB default)
//!   and on **watermark advance**; individual appends go straight to the file
//!   (no userspace buffering) so a process crash loses nothing and a machine
//!   crash loses at most the unsynced tail of the active segment;
//! - relay_ids are reserved in persisted blocks ([`RELAY_ID_RESERVE`]) so a
//!   crash can never reissue an already-assigned relay_id;
//! - a torn tail record (crash mid-append) is tolerated: recovery truncates
//!   the segment back to the last complete record;
//! - when the spool exceeds `max_bytes` (or `max_age`), whole **oldest sealed
//!   segments** are evicted with per-signal accounting (the active segment is
//!   never evicted, so the on-disk bound is `max_bytes` + one segment);
//! - the host volume dropping below `min_free_disk_bytes` (or an ENOSPC on
//!   write) is treated exactly like the byte bound being reached:
//!   evict-oldest, retry once, then reject the append with a typed
//!   [`SpoolFull`] error that callers count as a per-signal rejection —
//!   never a crash, never an unbounded error loop;
//! - [`Spool::reconfigure`] applies new bounds to the open spool immediately
//!   (shrinking evicts down to the new bound with normal accounting).
//!
//! Module layout: `meta.rs` owns the `relay.meta` file (watermark + relay-id
//! ceiling persistence), `segments.rs` owns segment files (naming, append,
//! rotation, scan and torn-tail recovery), `eviction.rs` owns release-on-ack
//! and budget/age/floor eviction with per-signal accounting, `disk.rs` owns
//! the free-disk probe, and `reader.rs` owns the [`SpoolReader`] cursor.

use std::collections::VecDeque;
use std::fs::{self, OpenOptions};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use addon_sdk::pb::{OtlpRelayFrame, TelemetryBatch};
use anyhow::{Context, Result, anyhow};
use prost::Message;
use tokio::sync::Notify;

mod disk;
mod eviction;
mod meta;
mod reader;
mod segments;
#[cfg(test)]
mod testutil;

pub use disk::{DiskFree, SystemDiskFree};
pub use eviction::EvictionCounters;
pub use reader::SpoolReader;

use meta::{RELAY_ID_RESERVE, read_meta, write_meta};
use segments::{ActiveSegment, SegmentMeta, recover_segments};

/// Default segment rotation threshold.
pub const DEFAULT_SEGMENT_MAX_BYTES: u64 = 8 * 1024 * 1024;

/// Default total spool budget.
pub const DEFAULT_SPOOL_MAX_BYTES: u64 = 256 * 1024 * 1024;

/// Default free-disk floor: the spool refuses to grow once the host volume
/// has less than this much space available (512 MiB).
pub const DEFAULT_MIN_FREE_DISK_BYTES: u64 = 512 * 1024 * 1024;

/// Spool sizing/location configuration (from `[agent_forward]`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpoolConfig {
    pub dir: PathBuf,
    /// Total on-disk budget before oldest-segment eviction (default 256 MiB).
    pub max_bytes: u64,
    /// Optional age bound: sealed segments older than this are evicted.
    pub max_age: Option<Duration>,
    /// Segment rotation threshold (default 8 MiB; configurable for tests).
    pub segment_max_bytes: u64,
    /// Free-disk floor (default 512 MiB; 0 disables): when the spool volume's
    /// available space falls below this, growth is treated as bound-reached.
    pub min_free_disk_bytes: u64,
}

impl SpoolConfig {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            max_bytes: DEFAULT_SPOOL_MAX_BYTES,
            max_age: None,
            segment_max_bytes: DEFAULT_SEGMENT_MAX_BYTES,
            min_free_disk_bytes: DEFAULT_MIN_FREE_DISK_BYTES,
        }
    }
}

/// Typed append-rejection error: the spool could not grow (free-disk floor
/// or ENOSPC) and evicting oldest sealed segments did not make room. Callers
/// ([`super::AgentForwardOutput`]) downcast this to convert the failure into
/// per-signal rejection accounting instead of a retryable transport error.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpoolFull {
    /// Available bytes on the spool volume at rejection time, if probeable.
    pub free_bytes: Option<u64>,
    /// The configured floor that could not be satisfied.
    pub min_free_disk_bytes: u64,
}

impl std::fmt::Display for SpoolFull {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.free_bytes {
            Some(free) => write!(
                f,
                "spool volume below free-disk floor ({free} bytes available, floor {})",
                self.min_free_disk_bytes
            ),
            None => write!(
                f,
                "spool volume out of space (floor {} bytes)",
                self.min_free_disk_bytes
            ),
        }
    }
}

impl std::error::Error for SpoolFull {}

/// Point-in-time spool accounting.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SpoolStats {
    /// Highest cumulatively-acked relay_id.
    pub watermark: u64,
    /// Next relay_id that will be assigned.
    pub next_relay_id: u64,
    /// Bytes currently on disk across all segments.
    pub total_bytes: u64,
    /// Frames currently stored on disk (including not-yet-released acked
    /// frames still inside the active segment).
    pub frames: u64,
    /// Cumulative unacked-eviction accounting since the spool was opened.
    pub evicted: EvictionCounters,
}

struct Inner {
    config: SpoolConfig,
    sealed: VecDeque<SegmentMeta>,
    active: Option<ActiveSegment>,
    next_relay_id: u64,
    /// Highest relay_id covered by the persisted reservation; ids below this
    /// may have been assigned before a crash and are never reused.
    ceiling: u64,
    watermark: u64,
    evicted: EvictionCounters,
    /// Free-disk probe for the floor check (injectable for tests).
    disk_free: Arc<dyn DiskFree>,
}

/// Durable, crash-safe relay spool. Shared (`Arc`) between the
/// [`super::AgentForwardOutput`] writer and the `RelayOtlp` reader.
pub struct Spool {
    inner: Mutex<Inner>,
    /// Wakes relay readers blocked in [`Spool::wait_for_frame_after`].
    notify: Notify,
}

impl Spool {
    /// Opens (or creates) a spool in `config.dir`, recovering segment state,
    /// truncating any torn tail record, and resuming the relay_id sequence
    /// past every id that may have been assigned before a crash.
    pub fn open(config: SpoolConfig) -> Result<Self> {
        Self::open_with_disk_free(config, Arc::new(SystemDiskFree))
    }

    /// [`Spool::open`] with an injected free-disk probe (tests use fakes
    /// instead of statvfs).
    pub fn open_with_disk_free(config: SpoolConfig, disk_free: Arc<dyn DiskFree>) -> Result<Self> {
        fs::create_dir_all(&config.dir).with_context(|| {
            format!("failed to create spool directory {}", config.dir.display())
        })?;

        let (watermark, ceiling) = read_meta(&config.dir)?;
        let (sealed, max_seen) = recover_segments(&config.dir)?;

        let next_relay_id = ceiling.max(max_seen + 1).max(watermark + 1).max(1);

        let mut inner = Inner {
            config,
            sealed,
            active: None,
            next_relay_id,
            ceiling: ceiling.max(next_relay_id),
            watermark,
            evicted: EvictionCounters::default(),
            disk_free,
        };

        inner.release_acked()?;

        // Resume the newest under-sized segment as the active segment so a
        // restart does not strand a tiny file per boot.
        if let Some(meta) = inner
            .sealed
            .pop_back_if(|seg| seg.bytes < inner.config.segment_max_bytes)
        {
            let file = OpenOptions::new()
                .append(true)
                .open(&meta.path)
                .with_context(|| format!("failed to reopen segment {}", meta.path.display()))?;
            inner.active = Some(ActiveSegment { meta, file });
        }

        inner.enforce_limits()?;

        Ok(Self {
            inner: Mutex::new(inner),
            notify: Notify::new(),
        })
    }

    /// Appends one batch as a new [`OtlpRelayFrame`], assigning the next
    /// persistent monotonic relay_id and stamping the spool-owned counters
    /// (`dropped` = cumulative unacked evictions, `queue_depth` = frames on
    /// disk) onto the batch before it is encoded. Returns the relay_id.
    ///
    /// When the spool volume is below the free-disk floor (or the write hits
    /// ENOSPC) the spool evicts oldest sealed segments and retries once; if
    /// that still cannot make room the error downcasts to [`SpoolFull`] so
    /// the caller can count a per-signal rejection instead of retrying.
    pub fn append_batch(&self, mut batch: TelemetryBatch) -> Result<u64> {
        let relay_id = {
            let mut inner = self.lock();

            // Free-disk floor before any growth (id reservation included:
            // the meta rewrite is itself a write on a possibly-full volume).
            // +64 over-estimates the frame wrapper + length prefix.
            inner.ensure_disk_floor(batch.encoded_len() as u64 + 64)?;

            let counters = batch.counters.get_or_insert_with(Default::default);
            counters.dropped = inner.evicted.total();
            counters.queue_depth = inner.total_frames();

            let relay_id = inner.reserve_relay_id()?;
            let frame = OtlpRelayFrame {
                relay_id,
                batch: Some(batch),
            };
            let mut payload = Vec::with_capacity(frame.encoded_len());
            frame
                .encode(&mut payload)
                .map_err(|e| anyhow!("failed to encode relay frame: {e}"))?;

            inner.append_with_enospc_retry(relay_id, &payload)?;
            inner.maybe_rotate()?;
            inner.enforce_limits()?;
            relay_id
        };

        self.notify.notify_waiters();
        Ok(relay_id)
    }

    /// Advances the cumulative ack watermark (fsynced) and releases sealed
    /// segments whose every frame is now acked. Acks are cumulative; stale or
    /// duplicate acks are ignored.
    pub fn advance_watermark(&self, acked_relay_id: u64) -> Result<()> {
        {
            let mut inner = self.lock();
            if acked_relay_id <= inner.watermark {
                return Ok(());
            }
            inner.watermark = acked_relay_id;
            // Defensive: never assign ids at or below an acked watermark.
            if inner.next_relay_id <= acked_relay_id {
                inner.next_relay_id = acked_relay_id + 1;
            }
            if inner.ceiling < inner.next_relay_id {
                inner.ceiling = inner.next_relay_id + RELAY_ID_RESERVE;
            }
            write_meta(&inner.config.dir, inner.watermark, inner.ceiling)?;
            inner.release_acked()?;
        }
        self.notify.notify_waiters();
        Ok(())
    }

    /// Current spool accounting (watermark, sizes, eviction counters).
    pub fn stats(&self) -> SpoolStats {
        let inner = self.lock();
        SpoolStats {
            watermark: inner.watermark,
            next_relay_id: inner.next_relay_id,
            total_bytes: inner.total_bytes(),
            frames: inner.total_frames(),
            evicted: inner.evicted,
        }
    }

    /// Total spool budget, for usage-ratio health checks.
    pub fn max_bytes(&self) -> u64 {
        self.lock().config.max_bytes
    }

    /// Snapshot of the spool's current configuration.
    pub fn config(&self) -> SpoolConfig {
        self.lock().config.clone()
    }

    /// Available bytes on the spool volume, per the configured probe
    /// (`None` when the platform cannot report it).
    pub fn disk_free_bytes(&self) -> Option<u64> {
        let inner = self.lock();
        inner.disk_free.available_bytes(&inner.config.dir)
    }

    /// Applies new bounds to the open spool immediately: `max_bytes`,
    /// `max_age`, `min_free_disk_bytes`, and `segment_max_bytes` take effect
    /// now (a smaller budget evicts oldest sealed segments down to the new
    /// bound, with normal per-signal eviction accounting). The spool
    /// directory is the spool's identity and cannot change here — callers
    /// must open a new spool to relocate.
    pub fn reconfigure(&self, config: SpoolConfig) -> Result<()> {
        let mut inner = self.lock();
        if config.dir != inner.config.dir {
            return Err(anyhow!(
                "spool reconfigure cannot change the spool directory (open at {}, requested {})",
                inner.config.dir.display(),
                config.dir.display()
            ));
        }
        inner.config = config;
        inner.enforce_limits()?;
        Ok(())
    }

    /// Creates a reader that resumes from the current ack watermark
    /// (drain-on-reconnect: every unacked frame is replayed in order).
    pub fn reader(self: &Arc<Self>) -> SpoolReader {
        let watermark = self.lock().watermark;
        SpoolReader {
            spool: Arc::clone(self),
            segment_first_id: None,
            offset: 0,
            position: watermark,
        }
    }

    /// Waits until a frame with relay_id greater than `relay_id` (and greater
    /// than the watermark) exists in the spool.
    pub async fn wait_for_frame_after(&self, relay_id: u64) {
        loop {
            let notified = self.notify.notified();
            {
                let inner = self.lock();
                let target = relay_id.max(inner.watermark);
                if inner.max_available_id() > target {
                    return;
                }
            }
            notified.await;
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

/// True when the error chain bottoms out in an out-of-space IO error.
fn is_enospc(err: &anyhow::Error) -> bool {
    err.chain().any(|cause| {
        cause
            .downcast_ref::<std::io::Error>()
            .is_some_and(|io| io.kind() == std::io::ErrorKind::StorageFull)
    })
}

impl Inner {
    fn total_bytes(&self) -> u64 {
        self.sealed.iter().map(|s| s.bytes).sum::<u64>()
            + self.active.as_ref().map_or(0, |a| a.meta.bytes)
    }

    /// Enforces the free-disk floor before growing by `incoming` bytes:
    /// below the floor is treated as bound-reached (evict oldest sealed
    /// segments, re-probe after each), and if eviction cannot restore the
    /// floor (or there is nothing left to evict) the append is rejected
    /// with [`SpoolFull`].
    fn ensure_disk_floor(&mut self, incoming: u64) -> Result<()> {
        let floor = self.config.min_free_disk_bytes;
        if floor == 0 {
            return Ok(());
        }
        let required = floor.saturating_add(incoming);
        let Some(mut free) = self.disk_free.available_bytes(&self.config.dir) else {
            return Ok(()); // unprobeable volume: fail open
        };
        if free >= required {
            return Ok(());
        }
        while free < required && !self.sealed.is_empty() {
            self.evict_front("free-disk floor reached")?;
            match self.disk_free.available_bytes(&self.config.dir) {
                Some(now_free) => free = now_free,
                None => return Ok(()),
            }
        }
        if free < required {
            return Err(anyhow::Error::new(SpoolFull {
                free_bytes: Some(free),
                min_free_disk_bytes: floor,
            }));
        }
        Ok(())
    }

    /// Appends, and on ENOSPC drops the partial write, evicts the oldest
    /// sealed segment, and retries exactly once; a second ENOSPC becomes a
    /// [`SpoolFull`] rejection. Non-ENOSPC errors propagate unchanged.
    fn append_with_enospc_retry(&mut self, relay_id: u64, payload: &[u8]) -> Result<()> {
        let Err(err) = self.append_encoded(relay_id, payload) else {
            return Ok(());
        };
        if !is_enospc(&err) {
            return Err(err);
        }
        self.truncate_active_tail();
        let evicted = if self.sealed.is_empty() {
            false
        } else {
            self.evict_front("ENOSPC on spool write")?;
            true
        };
        match self.append_encoded(relay_id, payload) {
            Ok(()) => Ok(()),
            Err(retry_err) if is_enospc(&retry_err) => {
                self.truncate_active_tail();
                if !evicted {
                    log::warn!("spool write hit ENOSPC with nothing left to evict");
                }
                Err(anyhow::Error::new(SpoolFull {
                    free_bytes: self.disk_free.available_bytes(&self.config.dir),
                    min_free_disk_bytes: self.config.min_free_disk_bytes,
                }))
            }
            Err(retry_err) => Err(retry_err),
        }
    }

    /// Discards any partially-written record so a retry appends at the last
    /// known-good offset instead of after torn bytes (best-effort: recovery
    /// truncates torn tails on reopen anyway).
    fn truncate_active_tail(&mut self) {
        if let Some(active) = &mut self.active
            && let Err(err) = active.file.set_len(active.meta.bytes)
        {
            log::warn!(
                "failed to truncate partial spool write in {}: {err}",
                active.meta.path.display()
            );
        }
    }

    fn total_frames(&self) -> u64 {
        self.sealed.iter().map(|s| s.frames).sum::<u64>()
            + self.active.as_ref().map_or(0, |a| a.meta.frames)
    }

    fn max_available_id(&self) -> u64 {
        self.active
            .as_ref()
            .map(|a| a.meta.last_relay_id)
            .or_else(|| self.sealed.back().map(|s| s.last_relay_id))
            .unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use addon_sdk::pb::TelemetryPayloadKind;

    use super::testutil::{FakeVolume, segment_count, small_config, test_batch};
    use super::{Spool, SpoolFull, is_enospc};

    #[test]
    fn free_disk_floor_evicts_oldest_and_keeps_accepting() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = small_config(dir.path());
        config.min_free_disk_bytes = 2048;

        // An 8 KiB fake volume: appends must start evicting oldest sealed
        // segments well before the spool's own (huge) max_bytes bound.
        let spool = Arc::new(
            Spool::open_with_disk_free(config, Arc::new(FakeVolume { capacity: 8192 })).unwrap(),
        );

        for _ in 0..100 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![7; 64]))
                .unwrap();
        }

        let stats = spool.stats();
        assert!(
            stats.evicted.total() > 0,
            "floor pressure must evict oldest sealed segments"
        );
        assert!(
            spool.disk_free_bytes().unwrap() + 512 + 256 >= 2048,
            "free space stays at the floor modulo one segment of slack, got {:?}",
            spool.disk_free_bytes()
        );
        // The newest data survives: the reader still yields frames.
        let mut reader = spool.reader();
        assert!(reader.try_next().unwrap().is_some());
    }

    #[test]
    fn free_disk_floor_rejects_with_spool_full_when_nothing_to_evict() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = small_config(dir.path());
        config.min_free_disk_bytes = 4096;

        // The whole volume is smaller than the floor: no eviction can help.
        let spool =
            Spool::open_with_disk_free(config, Arc::new(FakeVolume { capacity: 1024 })).unwrap();

        for _ in 0..3 {
            let err = spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![1; 32]))
                .expect_err("floor unsatisfiable: append must be rejected");
            let full = err
                .downcast_ref::<SpoolFull>()
                .expect("rejection must downcast to SpoolFull");
            assert_eq!(full.min_free_disk_bytes, 4096);
        }
        // Rejection is not corruption: the spool still answers stats.
        assert_eq!(spool.stats().frames, 0);
    }

    #[test]
    fn reconfigure_smaller_max_bytes_evicts_immediately() {
        let dir = tempfile::tempdir().unwrap();
        let config = small_config(dir.path());
        let spool = Arc::new(Spool::open(config.clone()).unwrap());

        for _ in 0..30 {
            spool
                .append_batch(test_batch(TelemetryPayloadKind::OtlpMetrics, vec![3; 64]))
                .unwrap();
        }
        let before = spool.stats();
        assert!(
            before.total_bytes > 1024,
            "fixture must exceed the new bound"
        );
        assert_eq!(before.evicted.total(), 0, "no eviction under the old bound");
        assert!(segment_count(dir.path()) > 2);

        let mut smaller = config;
        smaller.max_bytes = 1024;
        spool.reconfigure(smaller).unwrap();

        let after = spool.stats();
        assert!(
            after.total_bytes <= 1024 + 512,
            "shrink applies immediately (bound + one active segment), got {}",
            after.total_bytes
        );
        assert!(
            after.evicted.total() > 0,
            "shrink eviction uses normal accounting"
        );
        assert_eq!(spool.max_bytes(), 1024, "new bound is live");
    }

    #[test]
    fn reconfigure_rejects_directory_change() {
        let dir = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let spool = Spool::open(small_config(dir.path())).unwrap();

        let err = spool
            .reconfigure(small_config(other.path()))
            .expect_err("directory change must be rejected");
        assert!(
            err.to_string()
                .contains("cannot change the spool directory")
        );
    }

    #[test]
    fn enospc_detection_walks_the_context_chain() {
        let raw = std::io::Error::from(std::io::ErrorKind::StorageFull);
        let wrapped = anyhow::Error::new(raw).context("failed to append frame 7");
        assert!(is_enospc(&wrapped));

        let other: anyhow::Error =
            anyhow::Error::new(std::io::Error::from(std::io::ErrorKind::PermissionDenied))
                .context("failed to append");
        assert!(!is_enospc(&other));
    }
}
