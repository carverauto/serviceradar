use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostMemory {
    pub mem_total: u64,
    pub mem_free: u64,
    pub mem_shared: u64,
    pub mem_buffers: u64,
    pub mem_cached: u64,
    pub swap_total: u64,
    pub swap_free: u64,
    pub page_in: u32,
    pub page_out: u32,
    pub swap_in: u32,
    pub swap_out: u32,
}

pub(crate) fn parse_host_memory(input: &[u8]) -> IResult<&[u8], HostMemory> {
    let (input, mem_total) = be_u64(input)?;
    let (input, mem_free) = be_u64(input)?;
    let (input, mem_shared) = be_u64(input)?;
    let (input, mem_buffers) = be_u64(input)?;
    let (input, mem_cached) = be_u64(input)?;
    let (input, swap_total) = be_u64(input)?;
    let (input, swap_free) = be_u64(input)?;
    let (input, page_in) = be_u32(input)?;
    let (input, page_out) = be_u32(input)?;
    let (input, swap_in) = be_u32(input)?;
    let (input, swap_out) = be_u32(input)?;

    Ok((
        input,
        HostMemory {
            mem_total,
            mem_free,
            mem_shared,
            mem_buffers,
            mem_cached,
            swap_total,
            swap_free,
            page_in,
            page_out,
            swap_in,
            swap_out,
        },
    ))
}
