use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedEgressQueue {
    pub queue: u32,
}

pub(crate) fn parse_extended_egress_queue(input: &[u8]) -> IResult<&[u8], ExtendedEgressQueue> {
    let (input, queue) = be_u32(input)?;

    Ok((input, ExtendedEgressQueue { queue }))
}
