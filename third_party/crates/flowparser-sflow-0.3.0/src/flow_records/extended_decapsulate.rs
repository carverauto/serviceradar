use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedDecapsulateEgress {
    pub inner_header_offset: u32,
}

pub(crate) fn parse_extended_decapsulate_egress(
    input: &[u8],
) -> IResult<&[u8], ExtendedDecapsulateEgress> {
    let (input, inner_header_offset) = be_u32(input)?;

    Ok((
        input,
        ExtendedDecapsulateEgress {
            inner_header_offset,
        },
    ))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedDecapsulateIngress {
    pub inner_header_offset: u32,
}

pub(crate) fn parse_extended_decapsulate_ingress(
    input: &[u8],
) -> IResult<&[u8], ExtendedDecapsulateIngress> {
    let (input, inner_header_offset) = be_u32(input)?;

    Ok((
        input,
        ExtendedDecapsulateIngress {
            inner_header_offset,
        },
    ))
}
