use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::datagram::{AddressType, parse_address};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedRouter {
    pub next_hop: AddressType,
    pub src_mask_len: u32,
    pub dst_mask_len: u32,
}

pub(crate) fn parse_extended_router(input: &[u8]) -> IResult<&[u8], ExtendedRouter> {
    let (input, next_hop) = parse_address(input)?;
    let (input, src_mask_len) = be_u32(input)?;
    let (input, dst_mask_len) = be_u32(input)?;

    Ok((
        input,
        ExtendedRouter {
            next_hop,
            src_mask_len,
            dst_mask_len,
        },
    ))
}
