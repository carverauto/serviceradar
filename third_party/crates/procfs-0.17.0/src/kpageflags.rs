use crate::{process::Pfn, FileWrapper, ProcResult};

use std::{
    io::{BufReader, Read, Seek, SeekFrom},
    mem::size_of,
    path::Path,
};

pub use procfs_core::PhysicalPageFlags;

/// Parse physical memory flags accessing `/proc/kpageflags`.
///
/// Require root or CAP_SYS_ADMIN
pub struct KPageFlags {
    reader: BufReader<FileWrapper>,
}

impl KPageFlags {
    /// Get a parser from default `/proc/kpageflags`
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
        path.push("kpageflags");

        let reader = BufReader::new(FileWrapper::open(path)?);

        Ok(Self { reader })
    }

    /// Retrieve information in the page table entry for the PFN (page frame number) at index `page_index`.
    /// If you need to retrieve multiple PFNs, opt for [Self::get_range_info()] instead.
    ///
    /// Return Err if the PFN is not in RAM (see [crate::iomem()]):
    /// Io(Error { kind: UnexpectedEof, message: "failed to fill whole buffer" }, None)
    pub fn get_info(&mut self, pfn: Pfn) -> ProcResult<PhysicalPageFlags> {
        self.get_range_info(pfn, Pfn(pfn.0 + 1))
            .map(|mut vec| vec.pop().unwrap())
    }

    /// Retrieve information in the page table entry for the PFNs within range `start` (included) and `end` (excluded) PFNs.
    ///
    /// Return Err if any PFN is not in RAM (see [crate::iomem()]):
    /// Io(Error { kind: UnexpectedEof, message: "failed to fill whole buffer" }, None)
    pub fn get_range_info(&mut self, start: Pfn, end: Pfn) -> ProcResult<Vec<PhysicalPageFlags>> {
        let start_position = start.0 * size_of::<PhysicalPageFlags>() as u64;
        self.reader.seek(SeekFrom::Start(start_position))?;

        let mut page_infos = Vec::with_capacity((end.0 - start.0) as usize);
        for _ in start.0..end.0 {
            let mut info_bytes = [0; size_of::<PhysicalPageFlags>()];
            self.reader.read_exact(&mut info_bytes)?;
            page_infos.push(PhysicalPageFlags::parse_info(u64::from_ne_bytes(info_bytes)));
        }

        Ok(page_infos)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_kpageflags_parsing() {
        let pagemap_entry: u64 = 0b0000000000000000000000000000000000000000000000000000000000000001;
        let info = PhysicalPageFlags::parse_info(pagemap_entry);
        assert!(info == PhysicalPageFlags::LOCKED);
    }
}
