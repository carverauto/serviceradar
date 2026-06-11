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
//!   never evicted, so the on-disk bound is `max_bytes` + one segment).

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use addon_sdk::pb::{OtlpRelayFrame, TelemetryBatch, TelemetryPayloadKind};
use anyhow::{Context, Result, anyhow};
use log::{debug, warn};
use prost::Message;
use tokio::sync::Notify;

/// Default segment rotation threshold.
pub const DEFAULT_SEGMENT_MAX_BYTES: u64 = 8 * 1024 * 1024;

/// Default total spool budget.
pub const DEFAULT_SPOOL_MAX_BYTES: u64 = 256 * 1024 * 1024;

const META_FILE: &str = "relay.meta";
const META_TMP_FILE: &str = "relay.meta.tmp";
const META_MAGIC: &[u8; 8] = b"SRSPOOL1";
const SEGMENT_SUFFIX: &str = ".seg";

/// relay_ids are reserved (fsynced into the meta file) in blocks of this size
/// before being assigned, so monotonicity survives a crash that loses
/// unsynced appends: recovery resumes from the persisted ceiling, never
/// reissuing an id that may already have been sent (and acked) upstream.
const RELAY_ID_RESERVE: u64 = 65_536;

/// Sanity cap on a single length-prefixed record; anything larger is treated
/// as corruption during recovery (frames are chunked to <= 900 KiB upstream).
const MAX_RECORD_BYTES: u64 = 64 * 1024 * 1024;

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
}

impl SpoolConfig {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Self {
            dir: dir.into(),
            max_bytes: DEFAULT_SPOOL_MAX_BYTES,
            max_age: None,
            segment_max_bytes: DEFAULT_SEGMENT_MAX_BYTES,
        }
    }
}

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

#[derive(Debug, Clone)]
struct SegmentMeta {
    path: PathBuf,
    first_relay_id: u64,
    last_relay_id: u64,
    bytes: u64,
    frames: u64,
    sealed_at: SystemTime,
}

struct ActiveSegment {
    meta: SegmentMeta,
    file: File,
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
        fs::create_dir_all(&config.dir).with_context(|| {
            format!("failed to create spool directory {}", config.dir.display())
        })?;

        let (watermark, ceiling) = read_meta(&config.dir)?;

        let mut names: Vec<(u64, PathBuf)> = Vec::new();
        for entry in fs::read_dir(&config.dir)? {
            let entry = entry?;
            let path = entry.path();
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let Some(stem) = name.strip_suffix(SEGMENT_SUFFIX) else {
                continue;
            };
            let Ok(first_id) = stem.parse::<u64>() else {
                warn!("ignoring unrecognized spool file {name}");
                continue;
            };
            names.push((first_id, path));
        }
        names.sort_by_key(|(id, _)| *id);

        let mut sealed = VecDeque::new();
        let mut max_seen = 0u64;
        for (_, path) in names {
            match scan_segment(&path)? {
                Some(scan) => {
                    max_seen = max_seen.max(scan.last_relay_id);
                    let sealed_at = fs::metadata(&path)
                        .and_then(|m| m.modified())
                        .unwrap_or_else(|_| SystemTime::now());
                    sealed.push_back(SegmentMeta {
                        path,
                        first_relay_id: scan.first_relay_id,
                        last_relay_id: scan.last_relay_id,
                        bytes: scan.valid_bytes,
                        frames: scan.frames,
                        sealed_at,
                    });
                }
                None => {
                    debug!("removing empty spool segment {}", path.display());
                    let _ = fs::remove_file(&path);
                }
            }
        }

        let next_relay_id = ceiling.max(max_seen + 1).max(watermark + 1).max(1);

        let mut inner = Inner {
            config,
            sealed,
            active: None,
            next_relay_id,
            ceiling: ceiling.max(next_relay_id),
            watermark,
            evicted: EvictionCounters::default(),
        };

        inner.release_acked()?;

        // Resume the newest under-sized segment as the active segment so a
        // restart does not strand a tiny file per boot.
        if inner
            .sealed
            .back()
            .is_some_and(|seg| seg.bytes < inner.config.segment_max_bytes)
        {
            let meta = inner.sealed.pop_back().expect("checked back() above");
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
    pub fn append_batch(&self, mut batch: TelemetryBatch) -> Result<u64> {
        let relay_id = {
            let mut inner = self.lock();

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

            inner.append_encoded(relay_id, &payload)?;
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

impl Inner {
    fn total_bytes(&self) -> u64 {
        self.sealed.iter().map(|s| s.bytes).sum::<u64>()
            + self.active.as_ref().map_or(0, |a| a.meta.bytes)
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

    fn reserve_relay_id(&mut self) -> Result<u64> {
        let id = self.next_relay_id;
        if id >= self.ceiling {
            let new_ceiling = id + RELAY_ID_RESERVE;
            // Persist the reservation BEFORE the id is used so a crash can
            // never reissue it.
            write_meta(&self.config.dir, self.watermark, new_ceiling)?;
            self.ceiling = new_ceiling;
        }
        self.next_relay_id = id + 1;
        Ok(id)
    }

    fn append_encoded(&mut self, relay_id: u64, payload: &[u8]) -> Result<()> {
        if self.active.is_none() {
            let path = self.config.dir.join(segment_file_name(relay_id));
            let file = OpenOptions::new()
                .create_new(true)
                .append(true)
                .open(&path)
                .with_context(|| format!("failed to create segment {}", path.display()))?;
            self.active = Some(ActiveSegment {
                meta: SegmentMeta {
                    path,
                    first_relay_id: relay_id,
                    last_relay_id: relay_id,
                    bytes: 0,
                    frames: 0,
                    sealed_at: SystemTime::now(),
                },
                file,
            });
        }

        let active = self.active.as_mut().expect("active segment ensured above");
        let len = u32::try_from(payload.len())
            .map_err(|_| anyhow!("relay frame exceeds u32 length prefix"))?;
        active
            .file
            .write_all(&len.to_le_bytes())
            .and_then(|()| active.file.write_all(payload))
            .with_context(|| {
                format!(
                    "failed to append frame {relay_id} to {}",
                    active.meta.path.display()
                )
            })?;
        active.meta.bytes += 4 + payload.len() as u64;
        active.meta.last_relay_id = relay_id;
        active.meta.frames += 1;
        Ok(())
    }

    fn maybe_rotate(&mut self) -> Result<()> {
        let should_rotate = self
            .active
            .as_ref()
            .is_some_and(|a| a.meta.bytes >= self.config.segment_max_bytes);
        if should_rotate {
            self.rotate()?;
        }
        Ok(())
    }

    /// Seals the active segment: fsync data + directory + meta (the plan's
    /// "fsync on segment rotation" point).
    fn rotate(&mut self) -> Result<()> {
        let Some(active) = self.active.take() else {
            return Ok(());
        };
        active
            .file
            .sync_all()
            .with_context(|| format!("fsync failed for {}", active.meta.path.display()))?;
        sync_dir(&self.config.dir)?;
        write_meta(&self.config.dir, self.watermark, self.ceiling)?;
        let mut meta = active.meta;
        meta.sealed_at = SystemTime::now();
        self.sealed.push_back(meta);
        self.release_acked()?;
        Ok(())
    }

    /// Deletes sealed segments whose every frame is acked (NOT an eviction;
    /// no counters move).
    fn release_acked(&mut self) -> Result<()> {
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
    fn enforce_limits(&mut self) -> Result<()> {
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

    fn evict_front(&mut self, reason: &str) -> Result<()> {
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

    fn find_segment(&self, first_relay_id: u64) -> Option<SegmentMeta> {
        if let Some(active) = &self.active
            && active.meta.first_relay_id == first_relay_id
        {
            return Some(active.meta.clone());
        }
        self.sealed
            .iter()
            .find(|s| s.first_relay_id == first_relay_id)
            .cloned()
    }

    /// First segment (in relay_id order) containing any frame with
    /// relay_id > `target`.
    fn first_segment_after(&self, target: u64) -> Option<SegmentMeta> {
        self.sealed
            .iter()
            .find(|s| s.last_relay_id > target)
            .cloned()
            .or_else(|| {
                self.active
                    .as_ref()
                    .filter(|a| a.meta.last_relay_id > target)
                    .map(|a| a.meta.clone())
            })
    }

    /// Segment immediately following the one whose first id is `first`.
    fn next_segment_after(&self, first: u64) -> Option<SegmentMeta> {
        self.sealed
            .iter()
            .find(|s| s.first_relay_id > first)
            .cloned()
            .or_else(|| {
                self.active
                    .as_ref()
                    .filter(|a| a.meta.first_relay_id > first)
                    .map(|a| a.meta.clone())
            })
    }

    fn is_active(&self, first_relay_id: u64) -> bool {
        self.active
            .as_ref()
            .is_some_and(|a| a.meta.first_relay_id == first_relay_id)
    }
}

/// Cursor over the spool that yields unacked frames in relay_id order,
/// resuming from the ack watermark and skipping acked/evicted frames.
pub struct SpoolReader {
    spool: Arc<Spool>,
    /// First relay_id of the segment the cursor is in (segment identity).
    segment_first_id: Option<u64>,
    /// Byte offset of the next record within that segment.
    offset: u64,
    /// Highest relay_id returned so far (or the watermark at creation).
    position: u64,
}

impl SpoolReader {
    /// Highest relay_id this reader has returned (used as the
    /// [`Spool::wait_for_frame_after`] resume point).
    pub fn position(&self) -> u64 {
        self.position
    }

    /// Returns the next unacked frame, or `None` when the reader has caught
    /// up with the spool tail (callers then await
    /// [`Spool::wait_for_frame_after`]).
    pub fn try_next(&mut self) -> Result<Option<OtlpRelayFrame>> {
        let inner = self.spool.lock();
        let target = self.position.max(inner.watermark);
        loop {
            let seg = match self
                .segment_first_id
                .and_then(|first| inner.find_segment(first))
            {
                Some(seg) => seg,
                None => match inner.first_segment_after(target) {
                    Some(seg) => {
                        self.segment_first_id = Some(seg.first_relay_id);
                        self.offset = 0;
                        seg
                    }
                    None => {
                        // Caught up. If an active segment exists its frames
                        // are all <= target, so fast-forward the cursor past
                        // them instead of rescanning on every poll.
                        if let Some(active) = &inner.active {
                            self.segment_first_id = Some(active.meta.first_relay_id);
                            self.offset = active.meta.bytes;
                        }
                        return Ok(None);
                    }
                },
            };

            if self.offset >= seg.bytes {
                if inner.is_active(seg.first_relay_id) {
                    return Ok(None);
                }
                match inner.next_segment_after(seg.first_relay_id) {
                    Some(next) => {
                        self.segment_first_id = Some(next.first_relay_id);
                        self.offset = 0;
                        continue;
                    }
                    None => return Ok(None),
                }
            }

            let (frame, next_offset) = read_record(&seg.path, self.offset)?;
            self.segment_first_id = Some(seg.first_relay_id);
            self.offset = next_offset;
            if frame.relay_id <= target {
                continue;
            }
            self.position = frame.relay_id;
            return Ok(Some(frame));
        }
    }

    /// Awaits the next unacked frame.
    pub async fn next_frame(&mut self) -> Result<OtlpRelayFrame> {
        loop {
            if let Some(frame) = self.try_next()? {
                return Ok(frame);
            }
            let position = self.position;
            self.spool.wait_for_frame_after(position).await;
        }
    }
}

fn segment_file_name(first_relay_id: u64) -> String {
    format!("{first_relay_id:020}{SEGMENT_SUFFIX}")
}

fn sync_dir(dir: &Path) -> Result<()> {
    // Directory fsync is what makes renames/creates/unlinks durable on Linux;
    // harmless elsewhere.
    let handle =
        File::open(dir).with_context(|| format!("failed to open {} for fsync", dir.display()))?;
    handle
        .sync_all()
        .with_context(|| format!("fsync failed for directory {}", dir.display()))?;
    Ok(())
}

/// Atomically persists `(watermark, ceiling)`: write temp, fsync, rename,
/// fsync directory.
fn write_meta(dir: &Path, watermark: u64, ceiling: u64) -> Result<()> {
    let tmp = dir.join(META_TMP_FILE);
    let mut file =
        File::create(&tmp).with_context(|| format!("failed to create {}", tmp.display()))?;
    file.write_all(META_MAGIC)?;
    file.write_all(&watermark.to_le_bytes())?;
    file.write_all(&ceiling.to_le_bytes())?;
    file.sync_all()
        .with_context(|| format!("fsync failed for {}", tmp.display()))?;
    fs::rename(&tmp, dir.join(META_FILE))?;
    sync_dir(dir)?;
    Ok(())
}

/// Reads `(watermark, ceiling)`; a missing or corrupt meta file starts fresh
/// (segment scanning still recovers monotonicity from the data itself).
fn read_meta(dir: &Path) -> Result<(u64, u64)> {
    let path = dir.join(META_FILE);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((0, 1)),
        Err(e) => return Err(e).with_context(|| format!("failed to read {}", path.display())),
    };
    if bytes.len() != META_MAGIC.len() + 16 || &bytes[..META_MAGIC.len()] != META_MAGIC {
        warn!(
            "ignoring corrupt spool meta file {} ({} bytes)",
            path.display(),
            bytes.len()
        );
        return Ok((0, 1));
    }
    let watermark = u64::from_le_bytes(bytes[8..16].try_into().expect("length checked"));
    let ceiling = u64::from_le_bytes(bytes[16..24].try_into().expect("length checked"));
    Ok((watermark, ceiling.max(1)))
}

struct SegmentScan {
    first_relay_id: u64,
    last_relay_id: u64,
    frames: u64,
    valid_bytes: u64,
}

/// Scans a segment during recovery, truncating a torn tail record back to
/// the last complete frame. Returns `None` for an empty/garbage-only file.
fn scan_segment(path: &Path) -> Result<Option<SegmentScan>> {
    let mut file =
        File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let file_len = file.metadata()?.len();

    let mut offset = 0u64;
    let mut valid_bytes = 0u64;
    let mut first = None;
    let mut last = 0u64;
    let mut frames = 0u64;

    loop {
        if offset + 4 > file_len {
            break;
        }
        file.seek(SeekFrom::Start(offset))?;
        let mut len_buf = [0u8; 4];
        file.read_exact(&mut len_buf)?;
        let len = u64::from(u32::from_le_bytes(len_buf));
        if len == 0 || len > MAX_RECORD_BYTES || offset + 4 + len > file_len {
            break; // torn/garbage tail
        }
        let mut buf = vec![0u8; len as usize];
        file.read_exact(&mut buf)?;
        match OtlpRelayFrame::decode(buf.as_slice()) {
            Ok(frame) => {
                first.get_or_insert(frame.relay_id);
                last = frame.relay_id;
                frames += 1;
                offset += 4 + len;
                valid_bytes = offset;
            }
            Err(_) => break, // torn tail
        }
    }
    drop(file);

    if valid_bytes < file_len {
        warn!(
            "truncating torn tail of spool segment {} ({} -> {} bytes)",
            path.display(),
            file_len,
            valid_bytes
        );
        let trunc = OpenOptions::new()
            .write(true)
            .open(path)
            .with_context(|| format!("failed to reopen {} for truncation", path.display()))?;
        trunc.set_len(valid_bytes)?;
        trunc.sync_all()?;
    }

    Ok(first.map(|first_relay_id| SegmentScan {
        first_relay_id,
        last_relay_id: last,
        frames,
        valid_bytes,
    }))
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

/// Reads one length-prefixed frame at `offset`; returns the frame and the
/// offset of the next record.
fn read_record(path: &Path, offset: u64) -> Result<(OtlpRelayFrame, u64)> {
    let mut file =
        File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    file.seek(SeekFrom::Start(offset))?;
    let mut len_buf = [0u8; 4];
    file.read_exact(&mut len_buf)
        .with_context(|| format!("failed to read record header in {}", path.display()))?;
    let len = u64::from(u32::from_le_bytes(len_buf));
    if len == 0 || len > MAX_RECORD_BYTES {
        return Err(anyhow!(
            "corrupt record length {len} at offset {offset} in {}",
            path.display()
        ));
    }
    let mut buf = vec![0u8; len as usize];
    file.read_exact(&mut buf)
        .with_context(|| format!("failed to read record body in {}", path.display()))?;
    let frame = OtlpRelayFrame::decode(buf.as_slice())
        .with_context(|| format!("failed to decode frame at offset {offset}"))?;
    Ok((frame, offset + 4 + len))
}

#[cfg(test)]
mod tests {
    use super::*;
    use addon_sdk::pb::{TelemetryRecord, TelemetrySource};

    fn test_batch(kind: TelemetryPayloadKind, payload: Vec<u8>) -> TelemetryBatch {
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

    fn small_config(dir: &Path) -> SpoolConfig {
        SpoolConfig {
            dir: dir.to_path_buf(),
            max_bytes: DEFAULT_SPOOL_MAX_BYTES,
            max_age: None,
            segment_max_bytes: 512, // tiny segments so tests rotate quickly
        }
    }

    #[test]
    fn round_trip_preserves_frames_in_order() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let mut ids = Vec::new();
        for i in 0..10u8 {
            let id = spool
                .append_batch(test_batch(
                    TelemetryPayloadKind::OtlpTraces,
                    vec![i; 64 + i as usize],
                ))
                .unwrap();
            ids.push(id);
        }
        assert!(ids.windows(2).all(|w| w[1] == w[0] + 1), "ids monotonic");

        let mut reader = spool.reader();
        for (i, expected_id) in ids.iter().enumerate() {
            let frame = reader.try_next().unwrap().expect("frame available");
            assert_eq!(frame.relay_id, *expected_id);
            let batch = frame.batch.expect("batch present");
            assert_eq!(batch.records.len(), 1);
            assert_eq!(batch.records[0].payload, vec![i as u8; 64 + i]);
            let counters = batch.counters.expect("spool stamps counters");
            assert_eq!(counters.dropped, 0);
        }
        assert!(reader.try_next().unwrap().is_none(), "caught up");
    }

    #[test]
    fn reader_resumes_from_watermark() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let mut ids = Vec::new();
        for _ in 0..6 {
            ids.push(
                spool
                    .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![1; 32]))
                    .unwrap(),
            );
        }
        spool.advance_watermark(ids[2]).unwrap();

        let mut reader = spool.reader();
        let first = reader.try_next().unwrap().expect("unacked frame");
        assert_eq!(first.relay_id, ids[3], "resumes just past the watermark");
    }

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
    fn recovery_truncates_torn_tail_and_keeps_watermark() {
        let dir = tempfile::tempdir().unwrap();
        let config = small_config(dir.path());

        let (ids, watermark) = {
            let spool = Arc::new(Spool::open(config.clone()).unwrap());
            let mut ids = Vec::new();
            for _ in 0..5 {
                ids.push(
                    spool
                        .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![9; 48]))
                        .unwrap(),
                );
            }
            spool.advance_watermark(ids[1]).unwrap();
            (ids.clone(), ids[1])
        };

        // Simulate a crash mid-append: a torn record (length prefix promises
        // more bytes than exist) on the newest segment.
        let newest = newest_segment(dir.path());
        let mut file = OpenOptions::new().append(true).open(&newest).unwrap();
        file.write_all(&1000u32.to_le_bytes()).unwrap();
        file.write_all(&[0xAB; 10]).unwrap(); // only 10 of the promised 1000
        drop(file);

        let spool = Arc::new(Spool::open(config).unwrap());
        let stats = spool.stats();
        assert_eq!(stats.watermark, watermark, "watermark survives recovery");
        assert!(
            stats.next_relay_id > *ids.last().unwrap(),
            "relay ids stay monotonic after recovery"
        );

        // Every surviving record must be intact and the reader must resume
        // from the watermark.
        let mut reader = spool.reader();
        let mut seen = Vec::new();
        while let Some(frame) = reader.try_next().unwrap() {
            assert_eq!(
                frame.batch.unwrap().records[0].payload,
                vec![9u8; 48],
                "no torn frame may surface"
            );
            seen.push(frame.relay_id);
        }
        assert_eq!(seen, ids[2..].to_vec());
    }

    #[test]
    fn relay_ids_are_never_reused_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let config = small_config(dir.path());

        let last = {
            let spool = Spool::open(config.clone()).unwrap();
            let mut last = 0;
            for _ in 0..3 {
                last = spool
                    .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![5; 16]))
                    .unwrap();
            }
            last
        };

        // Wipe the segments (simulating eviction of everything) but keep the
        // meta file: the persisted ceiling must still prevent id reuse.
        for entry in fs::read_dir(dir.path()).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|e| e == "seg") {
                fs::remove_file(path).unwrap();
            }
        }

        let spool = Spool::open(config).unwrap();
        let next = spool
            .append_batch(test_batch(TelemetryPayloadKind::OtlpLogs, vec![6; 16]))
            .unwrap();
        assert!(next > last, "ceiling reservation prevents id reuse");
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

    #[tokio::test]
    async fn wait_for_frame_after_wakes_on_append() {
        let dir = tempfile::tempdir().unwrap();
        let spool = Arc::new(Spool::open(small_config(dir.path())).unwrap());

        let waiter = Arc::clone(&spool);
        let wait = tokio::spawn(async move { waiter.wait_for_frame_after(0).await });
        tokio::task::yield_now().await;

        spool
            .append_batch(test_batch(TelemetryPayloadKind::OtlpTraces, vec![1; 8]))
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), wait)
            .await
            .expect("waiter wakes after append")
            .unwrap();
    }

    fn segment_count(dir: &Path) -> usize {
        fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "seg"))
            .count()
    }

    fn newest_segment(dir: &Path) -> PathBuf {
        let mut segs: Vec<PathBuf> = fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|ext| ext == "seg"))
            .collect();
        segs.sort();
        segs.pop().expect("at least one segment")
    }
}
