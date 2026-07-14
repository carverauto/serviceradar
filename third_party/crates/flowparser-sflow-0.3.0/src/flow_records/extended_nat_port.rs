use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Extended NAT port translation data (enterprise=0, format=1020).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedNatPort {
    pub src_port: u32,
    pub dst_port: u32,
}

pub(crate) fn parse_extended_nat_port(input: &[u8]) -> IResult<&[u8], ExtendedNatPort> {
    let (input, src_port) = be_u32(input)?;
    let (input, dst_port) = be_u32(input)?;

    Ok((input, ExtendedNatPort { src_port, dst_port }))
}
