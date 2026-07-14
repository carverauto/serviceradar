use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedVlanTunnel {
    pub stack: Vec<u32>,
}

pub(crate) fn parse_extended_vlan_tunnel(input: &[u8]) -> IResult<&[u8], ExtendedVlanTunnel> {
    let (input, count) = be_u32(input)?;
    let cap = (count as usize).min(input.len() / 4);
    let mut stack = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..count {
        let (rest, val) = be_u32(input)?;
        stack.push(val);
        input = rest;
    }

    Ok((input, ExtendedVlanTunnel { stack }))
}
