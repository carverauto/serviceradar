use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fans {
    /// Total number of fans.
    pub total: u32,
    /// Number of failed fans.
    pub failed: u32,
    /// Fan speed (RPM or percentage).
    pub speed: u32,
}

pub(crate) fn parse_fans(input: &[u8]) -> IResult<&[u8], Fans> {
    let (input, total) = be_u32(input)?;
    let (input, failed) = be_u32(input)?;
    let (input, speed) = be_u32(input)?;

    Ok((
        input,
        Fans {
            total,
            failed,
            speed,
        },
    ))
}
