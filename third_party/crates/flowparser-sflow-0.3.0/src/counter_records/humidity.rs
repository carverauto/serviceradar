use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Humidity {
    /// Relative humidity percentage.
    pub relative_humidity: u32,
}

pub(crate) fn parse_humidity(input: &[u8]) -> IResult<&[u8], Humidity> {
    let (input, relative_humidity) = be_u32(input)?;

    Ok((input, Humidity { relative_humidity }))
}
