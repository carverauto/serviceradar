use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedQueue {
    pub queue_depth: u32,
}

pub(crate) fn parse_extended_queue(input: &[u8]) -> IResult<&[u8], ExtendedQueue> {
    let (input, queue_depth) = be_u32(input)?;

    Ok((input, ExtendedQueue { queue_depth }))
}
