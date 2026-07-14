use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueueLength {
    pub queue_index: u32,
    pub segment_size: u32,
    pub queue_segments: u32,
    pub queue_length_0: u32,
    pub queue_length_1: u32,
    pub queue_length_2: u32,
    pub queue_length_4: u32,
    pub queue_length_8: u32,
    pub queue_length_32: u32,
    pub queue_length_128: u32,
    pub queue_length_1024: u32,
    pub queue_length_more: u32,
    pub dropped: u32,
}

pub(crate) fn parse_queue_length(input: &[u8]) -> IResult<&[u8], QueueLength> {
    let (input, queue_index) = be_u32(input)?;
    let (input, segment_size) = be_u32(input)?;
    let (input, queue_segments) = be_u32(input)?;
    let (input, queue_length_0) = be_u32(input)?;
    let (input, queue_length_1) = be_u32(input)?;
    let (input, queue_length_2) = be_u32(input)?;
    let (input, queue_length_4) = be_u32(input)?;
    let (input, queue_length_8) = be_u32(input)?;
    let (input, queue_length_32) = be_u32(input)?;
    let (input, queue_length_128) = be_u32(input)?;
    let (input, queue_length_1024) = be_u32(input)?;
    let (input, queue_length_more) = be_u32(input)?;
    let (input, dropped) = be_u32(input)?;

    Ok((
        input,
        QueueLength {
            queue_index,
            segment_size,
            queue_segments,
            queue_length_0,
            queue_length_1,
            queue_length_2,
            queue_length_4,
            queue_length_8,
            queue_length_32,
            queue_length_128,
            queue_length_1024,
            queue_length_more,
            dropped,
        },
    ))
}
