//! Segment files: naming, append, rotation, recovery scan and record IO.
//!
//! Each segment is an append-only sequence of `[u32 LE len][OtlpRelayFrame]`
//! records, named after the first relay_id it contains. Recovery scans every
//! segment, truncating a torn tail record (crash mid-append) back to the
//! last complete frame.

use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use addon_sdk::pb::OtlpRelayFrame;
use anyhow::{Context, Result, anyhow};
use log::{debug, warn};
use prost::Message;

use super::Inner;
use super::meta::{sync_dir, write_meta};

const SEGMENT_SUFFIX: &str = ".seg";

/// Sanity cap on a single length-prefixed record; anything larger is treated
/// as corruption during recovery (frames are chunked to <= 900 KiB upstream).
pub(super) const MAX_RECORD_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone)]
pub(super) struct SegmentMeta {
    pub(super) path: PathBuf,
    pub(super) first_relay_id: u64,
    pub(super) last_relay_id: u64,
    pub(super) bytes: u64,
    pub(super) frames: u64,
    pub(super) sealed_at: SystemTime,
}

pub(super) struct ActiveSegment {
    pub(super) meta: SegmentMeta,
    pub(super) file: File,
}

impl Inner {
    pub(super) fn append_encoded(&mut self, relay_id: u64, payload: &[u8]) -> Result<()> {
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

    pub(super) fn maybe_rotate(&mut self) -> Result<()> {
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
}

fn segment_file_name(first_relay_id: u64) -> String {
    format!("{first_relay_id:020}{SEGMENT_SUFFIX}")
}

/// Lists and scans every segment file in `dir` (oldest-first by name),
/// truncating torn tails and deleting empty files. Returns the sealed
/// segment queue plus the highest relay_id seen on disk.
pub(super) fn recover_segments(dir: &Path) -> Result<(VecDeque<SegmentMeta>, u64)> {
    let mut names: Vec<(u64, PathBuf)> = Vec::new();
    for entry in fs::read_dir(dir)? {
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

    Ok((sealed, max_seen))
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

/// Reads one length-prefixed frame at `offset`; returns the frame and the
/// offset of the next record.
pub(super) fn read_record(path: &Path, offset: u64) -> Result<(OtlpRelayFrame, u64)> {
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
    use std::fs::OpenOptions;
    use std::io::Write;
    use std::sync::Arc;

    use addon_sdk::pb::TelemetryPayloadKind;

    use crate::agent_forward::spool::Spool;
    use crate::agent_forward::spool::testutil::{newest_segment, small_config, test_batch};

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
}
