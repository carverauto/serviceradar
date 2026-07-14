use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::datagram::{AddressType, parse_address};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AsPathSegment {
    pub segment_type: u32,
    pub values: Vec<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedGateway {
    pub next_hop: AddressType,
    pub as_number: u32,
    pub src_as: u32,
    pub src_peer_as: u32,
    pub as_path_segments: Vec<AsPathSegment>,
    pub communities: Vec<u32>,
}

fn parse_as_path_segment(input: &[u8]) -> IResult<&[u8], AsPathSegment> {
    let (input, segment_type) = be_u32(input)?;
    let (input, count) = be_u32(input)?;
    // Cap capacity: each value is 4 bytes
    let cap = (count as usize).min(input.len() / 4);
    let mut values = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..count {
        let (rest, val) = be_u32(input)?;
        values.push(val);
        input = rest;
    }
    Ok((
        input,
        AsPathSegment {
            segment_type,
            values,
        },
    ))
}

pub(crate) fn parse_extended_gateway(input: &[u8]) -> IResult<&[u8], ExtendedGateway> {
    let (input, next_hop) = parse_address(input)?;
    let (input, as_number) = be_u32(input)?;
    let (input, src_as) = be_u32(input)?;
    let (input, src_peer_as) = be_u32(input)?;
    let (input, as_path_count) = be_u32(input)?;

    // Cap capacity: each segment needs at least 8 bytes (type + count)
    let cap = (as_path_count as usize).min(input.len() / 8);
    let mut as_path_segments = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..as_path_count {
        let (rest, segment) = parse_as_path_segment(input)?;
        as_path_segments.push(segment);
        input = rest;
    }

    let (input, communities_count) = be_u32(input)?;
    // Cap capacity: each community is 4 bytes
    let cap = (communities_count as usize).min(input.len() / 4);
    let mut communities = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..communities_count {
        let (rest, val) = be_u32(input)?;
        communities.push(val);
        input = rest;
    }

    Ok((
        input,
        ExtendedGateway {
            next_hop,
            as_number,
            src_as,
            src_peer_as,
            as_path_segments,
            communities,
        },
    ))
}
