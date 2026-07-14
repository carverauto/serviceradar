use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MemcacheOperation {
    pub protocol: u32,
    pub cmd: u32,
    pub key: String,
    pub nkeys: u32,
    pub value_bytes: u32,
    pub duration_us: u32,
    pub status: u32,
}

pub(crate) fn parse_memcache_operation(input: &[u8]) -> IResult<&[u8], MemcacheOperation> {
    let (input, protocol) = be_u32(input)?;
    let (input, cmd) = be_u32(input)?;
    let (input, key) = parse_sflow_string(input)?;
    let (input, nkeys) = be_u32(input)?;
    let (input, value_bytes) = be_u32(input)?;
    let (input, duration_us) = be_u32(input)?;
    let (input, status) = be_u32(input)?;

    Ok((
        input,
        MemcacheOperation {
            protocol,
            cmd,
            key,
            nkeys,
            value_bytes,
            duration_us,
            status,
        },
    ))
}
