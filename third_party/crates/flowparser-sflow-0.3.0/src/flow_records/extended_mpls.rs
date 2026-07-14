use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::datagram::{AddressType, parse_address};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedMpls {
    pub next_hop: AddressType,
    pub in_label_stack: Vec<u32>,
    pub out_label_stack: Vec<u32>,
}

fn parse_label_stack(input: &[u8]) -> IResult<&[u8], Vec<u32>> {
    let (input, count) = be_u32(input)?;
    let cap = (count as usize).min(input.len() / 4);
    let mut labels = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..count {
        let (rest, val) = be_u32(input)?;
        labels.push(val);
        input = rest;
    }
    Ok((input, labels))
}

pub(crate) fn parse_extended_mpls(input: &[u8]) -> IResult<&[u8], ExtendedMpls> {
    let (input, next_hop) = parse_address(input)?;
    let (input, in_label_stack) = parse_label_stack(input)?;
    let (input, out_label_stack) = parse_label_stack(input)?;

    Ok((
        input,
        ExtendedMpls {
            next_hop,
            in_label_stack,
            out_label_stack,
        },
    ))
}
