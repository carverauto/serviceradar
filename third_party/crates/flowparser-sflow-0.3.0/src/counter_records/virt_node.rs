use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VirtNode {
    pub mhz: u32,
    pub cpus: u32,
    pub memory: u64,
    pub memory_free: u64,
    pub num_domains: u32,
}

pub(crate) fn parse_virt_node(input: &[u8]) -> IResult<&[u8], VirtNode> {
    let (input, mhz) = be_u32(input)?;
    let (input, cpus) = be_u32(input)?;
    let (input, memory) = be_u64(input)?;
    let (input, memory_free) = be_u64(input)?;
    let (input, num_domains) = be_u32(input)?;

    Ok((
        input,
        VirtNode {
            mhz,
            cpus,
            memory,
            memory_free,
            num_domains,
        },
    ))
}
