use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SlowPathCounts {
    pub unknown: u32,
    pub other: u32,
    pub cam_miss: u32,
    pub cam_full: u32,
    pub no_hw_support: u32,
    pub cntrl: u32,
}

pub(crate) fn parse_slow_path_counts(input: &[u8]) -> IResult<&[u8], SlowPathCounts> {
    let (input, unknown) = be_u32(input)?;
    let (input, other) = be_u32(input)?;
    let (input, cam_miss) = be_u32(input)?;
    let (input, cam_full) = be_u32(input)?;
    let (input, no_hw_support) = be_u32(input)?;
    let (input, cntrl) = be_u32(input)?;

    Ok((
        input,
        SlowPathCounts {
            unknown,
            other,
            cam_miss,
            cam_full,
            no_hw_support,
            cntrl,
        },
    ))
}
