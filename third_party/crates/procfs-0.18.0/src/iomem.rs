use super::ProcResult;
use crate::Current;
use procfs_core::{Iomem, PhysicalMemoryMap};

impl Current for Iomem {
    const PATH: &'static str = "/proc/iomem";
}

/// Reads and parses the `/proc/iomem`, returning an error if there are problems.
///
/// Requires root, otherwise every memory address will be zero.
pub fn iomem() -> ProcResult<Vec<(usize, PhysicalMemoryMap)>> {
    Iomem::current().map(|v| v.0)
}
