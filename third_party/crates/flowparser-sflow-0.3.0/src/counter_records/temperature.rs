use nom::IResult;
use nom::number::complete::{be_i32, be_u32};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Temperature {
    /// Minimum temperature reading in degrees Celsius.
    pub minimum: i32,
    /// Maximum temperature reading in degrees Celsius.
    pub maximum: i32,
    /// Sensor error count.
    pub errors: u32,
}

pub(crate) fn parse_temperature(input: &[u8]) -> IResult<&[u8], Temperature> {
    let (input, minimum) = be_i32(input)?;
    let (input, maximum) = be_i32(input)?;
    let (input, errors) = be_u32(input)?;

    Ok((
        input,
        Temperature {
            minimum,
            maximum,
            errors,
        },
    ))
}
