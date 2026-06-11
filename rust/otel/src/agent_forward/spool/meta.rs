//! `relay.meta` persistence: the ack watermark and the relay-id ceiling.
//!
//! The meta file is the spool's only mutable-in-place state; it is always
//! replaced atomically (write temp, fsync, rename, fsync directory) so a
//! crash can never leave a half-written watermark or ceiling on disk.

use std::fs::{self, File};
use std::io::Write;
use std::path::Path;

use anyhow::{Context, Result};
use log::warn;

use super::Inner;

const META_FILE: &str = "relay.meta";
const META_TMP_FILE: &str = "relay.meta.tmp";
const META_MAGIC: &[u8; 8] = b"SRSPOOL1";

/// relay_ids are reserved (fsynced into the meta file) in blocks of this size
/// before being assigned, so monotonicity survives a crash that loses
/// unsynced appends: recovery resumes from the persisted ceiling, never
/// reissuing an id that may already have been sent (and acked) upstream.
pub(super) const RELAY_ID_RESERVE: u64 = 65_536;

impl Inner {
    pub(super) fn reserve_relay_id(&mut self) -> Result<u64> {
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
}

pub(super) fn sync_dir(dir: &Path) -> Result<()> {
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
pub(super) fn write_meta(dir: &Path, watermark: u64, ceiling: u64) -> Result<()> {
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
pub(super) fn read_meta(dir: &Path) -> Result<(u64, u64)> {
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

#[cfg(test)]
mod tests {
    use std::fs;

    use addon_sdk::pb::TelemetryPayloadKind;

    use crate::agent_forward::spool::Spool;
    use crate::agent_forward::spool::testutil::{small_config, test_batch};

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
}
