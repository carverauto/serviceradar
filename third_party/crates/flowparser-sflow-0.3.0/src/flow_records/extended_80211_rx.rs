use mac_address::MacAddress;
use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Extended80211Rx {
    pub ssid: String,
    pub bssid: MacAddress,
    pub version: u32,
    pub channel: u32,
    pub speed: u64,
    pub rsni: u32,
    pub rcpi: u32,
    pub packet_duration_us: u32,
}

fn parse_mac(input: &[u8]) -> IResult<&[u8], MacAddress> {
    if input.len() < 6 {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Eof,
        )));
    }
    let bytes: [u8; 6] = [input[0], input[1], input[2], input[3], input[4], input[5]];
    Ok((&input[6..], MacAddress::new(bytes)))
}

pub(crate) fn parse_extended_80211_rx(input: &[u8]) -> IResult<&[u8], Extended80211Rx> {
    let (input, ssid) = parse_sflow_string(input)?;
    let (input, bssid) = parse_mac(input)?;
    let (input, version) = be_u32(input)?;
    let (input, channel) = be_u32(input)?;
    let (input, speed) = be_u64(input)?;
    let (input, rsni) = be_u32(input)?;
    let (input, rcpi) = be_u32(input)?;
    let (input, packet_duration_us) = be_u32(input)?;

    Ok((
        input,
        Extended80211Rx {
            ssid,
            bssid,
            version,
            channel,
            speed,
            rsni,
            rcpi,
            packet_duration_us,
        },
    ))
}
