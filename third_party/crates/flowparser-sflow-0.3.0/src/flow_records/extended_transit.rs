use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedTransit {
    pub transit_delay_ns: u32,
}

pub(crate) fn parse_extended_transit(input: &[u8]) -> IResult<&[u8], ExtendedTransit> {
    let (input, transit_delay_ns) = be_u32(input)?;

    Ok((input, ExtendedTransit { transit_delay_ns }))
}
