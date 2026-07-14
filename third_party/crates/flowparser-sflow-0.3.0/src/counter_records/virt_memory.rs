use nom::IResult;
use nom::number::complete::be_u64;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VirtMemory {
    /// Memory used by domain in bytes.
    pub memory: u64,
    /// Maximum memory allowed in bytes.
    pub max_memory: u64,
}

pub(crate) fn parse_virt_memory(input: &[u8]) -> IResult<&[u8], VirtMemory> {
    let (input, memory) = be_u64(input)?;
    let (input, max_memory) = be_u64(input)?;

    Ok((input, VirtMemory { memory, max_memory }))
}
