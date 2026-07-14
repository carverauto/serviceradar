use std::{
    io::{BufReader, Read, Seek, SeekFrom},
    mem::size_of,
    path::Path,
};

use crate::{process::Pfn, FileWrapper};

use super::ProcResult;

/// Parse physical memory references accessing `/proc/kpagecount`
///
/// Require root or CAP_SYS_ADMIN
pub struct KPageCount {
    reader: BufReader<FileWrapper>,
}

impl KPageCount {
    /// Get a parser from default `/proc/kpagecount`
    ///
    /// Return `Err` if process is not running as root or don't have CAP_SYS_ADMIN
    pub fn new() -> ProcResult<Self> {
        Self::from_custom_root("/proc")
    }

    /// Get a parser from custom `/proc`
    ///
    /// Return `Err` if process is not running as root or don't have CAP_SYS_ADMIN
    pub fn from_custom_root<P: AsRef<Path>>(root: P) -> ProcResult<Self> {
        let mut path = root.as_ref().to_path_buf();
        path.push("kpagecount");

        let reader = BufReader::new(FileWrapper::open(path)?);

        Ok(Self { reader })
    }

    /// Get the number of references to physical memory at `pfn`
    ///
    /// Return Err if pfn is not in RAM. See [crate::iomem()] for a list of valid physical RAM addresses
    ///
    /// See [crate::process::Process::pagemap] and [crate::process::MemoryPageFlags::get_page_frame_number]
    pub fn get_count_at_pfn(&mut self, pfn: Pfn) -> ProcResult<u64> {
        self.get_count_in_range(pfn, Pfn(pfn.0 + 1))
            .map(|mut vec| vec.pop().unwrap())
    }

    /// Get the number of references to physical memory at for PFNs within `start` and `end` PFNs, `end` is excluded
    ///
    /// Return Err if any pfn is not in RAM. See [crate::iomem()] for a list of valid physical RAM addresses
    ///
    /// See [crate::process::Process::pagemap] and [crate::process::MemoryPageFlags::get_page_frame_number]
    pub fn get_count_in_range(&mut self, start: Pfn, end: Pfn) -> ProcResult<Vec<u64>> {
        let mut result = Vec::with_capacity((end.0 - start.0) as usize);

        let start_position = start.0 * size_of::<u64>() as u64;
        self.reader.seek(SeekFrom::Start(start_position))?;

        for _pfn in start.0..end.0 {
            // Each entry is a 64 bits counter
            let mut buf = [0; size_of::<u64>()];

            self.reader.read_exact(&mut buf)?;
            let page_references: u64 = u64::from_le_bytes(buf);

            result.push(page_references);
        }

        Ok(result)
    }
}
