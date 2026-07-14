use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Energy {
    /// Voltage in millivolts.
    pub voltage: u32,
    /// Current in milliamps.
    pub current: u32,
    /// Real power in milliwatts.
    pub real_power: u32,
    /// Power factor percentage (0 for DC).
    pub power_factor: u32,
    /// Energy consumed in millijoules.
    pub energy: u32,
    /// Error count.
    pub errors: u32,
}

pub(crate) fn parse_energy(input: &[u8]) -> IResult<&[u8], Energy> {
    let (input, voltage) = be_u32(input)?;
    let (input, current) = be_u32(input)?;
    let (input, real_power) = be_u32(input)?;
    let (input, power_factor) = be_u32(input)?;
    let (input, energy) = be_u32(input)?;
    let (input, errors) = be_u32(input)?;

    Ok((
        input,
        Energy {
            voltage,
            current,
            real_power,
            power_factor,
            energy,
            errors,
        },
    ))
}
