use nom::IResult;
use nom::number::complete::{be_i32, be_u32};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SfpLane {
    pub tx_bias_current: u32,
    pub tx_power: u32,
    pub tx_power_min: u32,
    pub tx_power_max: u32,
    pub tx_wavelength: u32,
    pub rx_power: u32,
    pub rx_power_min: u32,
    pub rx_power_max: u32,
    pub rx_wavelength: u32,
    pub bias_current: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Sfp {
    pub module_id: u32,
    pub module_num_lanes: u32,
    pub module_supply_voltage: u32,
    /// Temperature in units of 1/1000 degree Celsius (signed).
    pub module_temperature: i32,
    pub lanes: Vec<SfpLane>,
}

fn parse_sfp_lane(input: &[u8]) -> IResult<&[u8], SfpLane> {
    let (input, tx_bias_current) = be_u32(input)?;
    let (input, tx_power) = be_u32(input)?;
    let (input, tx_power_min) = be_u32(input)?;
    let (input, tx_power_max) = be_u32(input)?;
    let (input, tx_wavelength) = be_u32(input)?;
    let (input, rx_power) = be_u32(input)?;
    let (input, rx_power_min) = be_u32(input)?;
    let (input, rx_power_max) = be_u32(input)?;
    let (input, rx_wavelength) = be_u32(input)?;
    let (input, bias_current) = be_u32(input)?;

    Ok((
        input,
        SfpLane {
            tx_bias_current,
            tx_power,
            tx_power_min,
            tx_power_max,
            tx_wavelength,
            rx_power,
            rx_power_min,
            rx_power_max,
            rx_wavelength,
            bias_current,
        },
    ))
}

pub(crate) fn parse_sfp(input: &[u8]) -> IResult<&[u8], Sfp> {
    let (input, module_id) = be_u32(input)?;
    let (input, module_num_lanes) = be_u32(input)?;
    let (input, module_supply_voltage) = be_u32(input)?;
    let (input, module_temperature) = be_i32(input)?;

    // Each lane is 10 u32 fields = 40 bytes
    let cap = (module_num_lanes as usize).min(input.len() / 40);
    let mut lanes = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..module_num_lanes {
        let (rest, lane) = parse_sfp_lane(input)?;
        lanes.push(lane);
        input = rest;
    }

    Ok((
        input,
        Sfp {
            module_id,
            module_num_lanes,
            module_supply_voltage,
            module_temperature,
            lanes,
        },
    ))
}
