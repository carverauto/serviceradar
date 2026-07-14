use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VirtDiskIo {
    /// Logical disk size in bytes.
    pub capacity: u64,
    /// Current disk allocation in bytes.
    pub allocation: u64,
    /// Remaining free bytes on disk.
    pub available: u64,
    /// Number of read requests.
    pub rd_req: u32,
    /// Bytes read.
    pub rd_bytes: u64,
    /// Number of write requests.
    pub wr_req: u32,
    /// Bytes written.
    pub wr_bytes: u64,
    /// Read/write errors.
    pub errs: u32,
}

pub(crate) fn parse_virt_disk_io(input: &[u8]) -> IResult<&[u8], VirtDiskIo> {
    let (input, capacity) = be_u64(input)?;
    let (input, allocation) = be_u64(input)?;
    let (input, available) = be_u64(input)?;
    let (input, rd_req) = be_u32(input)?;
    let (input, rd_bytes) = be_u64(input)?;
    let (input, wr_req) = be_u32(input)?;
    let (input, wr_bytes) = be_u64(input)?;
    let (input, errs) = be_u32(input)?;

    Ok((
        input,
        VirtDiskIo {
            capacity,
            allocation,
            available,
            rd_req,
            rd_bytes,
            wr_req,
            wr_bytes,
            errs,
        },
    ))
}
