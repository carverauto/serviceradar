use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RadioUtilization {
    pub elapsed_time: u32,
    pub on_channel_time: u32,
    pub on_channel_busy_time: u32,
}

pub(crate) fn parse_radio_utilization(input: &[u8]) -> IResult<&[u8], RadioUtilization> {
    let (input, elapsed_time) = be_u32(input)?;
    let (input, on_channel_time) = be_u32(input)?;
    let (input, on_channel_busy_time) = be_u32(input)?;

    Ok((
        input,
        RadioUtilization {
            elapsed_time,
            on_channel_time,
            on_channel_busy_time,
        },
    ))
}
