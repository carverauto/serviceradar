use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostDiskIo {
    pub disk_total: u64,
    pub disk_free: u64,
    /// Percentage of disk used (0-100, scaled by 100 in some implementations).
    pub part_max_used: u32,
    pub reads: u32,
    pub bytes_read: u64,
    pub read_time: u32,
    pub writes: u32,
    pub bytes_written: u64,
    pub write_time: u32,
}

pub(crate) fn parse_host_disk_io(input: &[u8]) -> IResult<&[u8], HostDiskIo> {
    let (input, disk_total) = be_u64(input)?;
    let (input, disk_free) = be_u64(input)?;
    let (input, part_max_used) = be_u32(input)?;
    let (input, reads) = be_u32(input)?;
    let (input, bytes_read) = be_u64(input)?;
    let (input, read_time) = be_u32(input)?;
    let (input, writes) = be_u32(input)?;
    let (input, bytes_written) = be_u64(input)?;
    let (input, write_time) = be_u32(input)?;

    Ok((
        input,
        HostDiskIo {
            disk_total,
            disk_free,
            part_max_used,
            reads,
            bytes_read,
            read_time,
            writes,
            bytes_written,
            write_time,
        },
    ))
}
