use crate::{FileWrapper, ProcResult};
use procfs_core::process::PageInfo;
use std::{
    io::{BufReader, Read, Seek, SeekFrom},
    mem::size_of,
    ops::{Bound, RangeBounds},
};

impl super::Process {
    /// Returns a struct that can be used to access information in the `/proc/pid/pagemap` file.
    pub fn pagemap(&self) -> ProcResult<PageMap> {
        let path = self.root.join("pagemap");
        let file = FileWrapper::open(&path)?;
        Ok(PageMap::from_file_wrapper(file))
    }
}

/// Parses page table entries accessing `/proc/<pid>/pagemap`.
pub struct PageMap {
    reader: BufReader<FileWrapper>,
}

impl PageMap {
    pub(crate) fn from_file_wrapper(file: FileWrapper) -> Self {
        Self {
            reader: BufReader::new(file),
        }
    }

    /// Retrieves information in the page table entry for the page at index `page_index`.
    ///
    /// Some mappings are not accessible, and will return an Err: `vsyscall`
    pub fn get_info(&mut self, page_index: usize) -> ProcResult<PageInfo> {
        self.get_range_info(page_index..page_index + 1)
            .map(|mut vec| vec.pop().unwrap())
    }

    /// Retrieves information in the page table entry for the pages with index in range `page_range`.
    pub fn get_range_info(&mut self, page_range: impl RangeBounds<usize>) -> ProcResult<Vec<PageInfo>> {
        // `start` is always included
        let start = match page_range.start_bound() {
            Bound::Included(v) => *v,
            Bound::Excluded(v) => *v + 1,
            Bound::Unbounded => 0,
        };

        // `end` is always excluded
        let end = match page_range.end_bound() {
            Bound::Included(v) => *v + 1,
            Bound::Excluded(v) => *v,
            Bound::Unbounded => std::usize::MAX / crate::page_size() as usize,
        };

        let start_position = (start * size_of::<u64>()) as u64;
        self.reader.seek(SeekFrom::Start(start_position))?;

        let mut page_infos = Vec::with_capacity((end - start) as usize);
        for _ in start..end {
            let mut info_bytes = [0; size_of::<u64>()];
            self.reader.read_exact(&mut info_bytes)?;
            page_infos.push(PageInfo::parse_info(u64::from_ne_bytes(info_bytes)));
        }

        Ok(page_infos)
    }
}
