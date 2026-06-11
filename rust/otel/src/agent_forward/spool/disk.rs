//! Free-disk probing for the spool's free-disk floor.
//!
//! The spool must never fill the host volume: before growing it asks a
//! [`DiskFree`] probe how much space the spool volume has left and treats
//! "below the configured floor" exactly like its own byte bound being
//! reached (evict-oldest, then counted rejection). The probe is a trait so
//! tests inject deterministic fakes instead of shelling out to the real
//! filesystem.

use std::path::Path;

/// Reports the available bytes on the volume holding a path.
pub trait DiskFree: Send + Sync + 'static {
    /// Available (unprivileged) bytes on the volume holding `path`, or
    /// `None` when the platform cannot report it. `None` disables the floor
    /// check (fail-open: an unprobeable volume must not reject telemetry).
    fn available_bytes(&self, path: &Path) -> Option<u64>;
}

/// The real probe: `statvfs(3)` via rustix on unix, a no-op elsewhere.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemDiskFree;

impl DiskFree for SystemDiskFree {
    #[cfg(unix)]
    fn available_bytes(&self, path: &Path) -> Option<u64> {
        match rustix::fs::statvfs(path) {
            // f_bavail is the unprivileged-available block count; multiplied
            // by the fragment size it matches what `df` reports as "Avail".
            Ok(vfs) => Some(vfs.f_bavail.saturating_mul(vfs.f_frsize)),
            Err(err) => {
                log::debug!("statvfs failed for {}: {err}", path.display());
                None
            }
        }
    }

    /// Windows/non-unix: no statvfs; the floor check is disabled.
    #[cfg(not(unix))]
    fn available_bytes(&self, _path: &Path) -> Option<u64> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_probe_reports_space_for_an_existing_dir() {
        let dir = tempfile::tempdir().unwrap();
        let free = SystemDiskFree.available_bytes(dir.path());
        // On unix a tempdir's volume always has *some* answer; on other
        // platforms the probe is defined to return None.
        if cfg!(unix) {
            assert!(free.is_some());
        } else {
            assert!(free.is_none());
        }
    }

    #[cfg(unix)]
    #[test]
    fn system_probe_returns_none_for_missing_path() {
        assert!(
            SystemDiskFree
                .available_bytes(Path::new("/nonexistent/serviceradar/spool"))
                .is_none()
        );
    }
}
