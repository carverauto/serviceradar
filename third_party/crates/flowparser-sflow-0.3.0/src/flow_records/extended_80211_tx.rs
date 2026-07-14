use mac_address::MacAddress;
use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Extended80211Tx {
    pub ssid: String,
    pub bssid: MacAddress,
    pub version: u32,
    pub transmissions: u32,
    pub packet_duration_us: u32,
    pub retrans_duration_us: u32,
    pub channel: u32,
    pub speed: u64,
    pub power: u32,
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

pub(crate) fn parse_extended_80211_tx(input: &[u8]) -> IResult<&[u8], Extended80211Tx> {
    let (input, ssid) = parse_sflow_string(input)?;
    let (input, bssid) = parse_mac(input)?;
    let (input, version) = be_u32(input)?;
    let (input, transmissions) = be_u32(input)?;
    let (input, packet_duration_us) = be_u32(input)?;
    let (input, retrans_duration_us) = be_u32(input)?;
    let (input, channel) = be_u32(input)?;
    let (input, speed) = be_u64(input)?;
    let (input, power) = be_u32(input)?;

    Ok((
        input,
        Extended80211Tx {
            ssid,
            bssid,
            version,
            transmissions,
            packet_duration_us,
            retrans_duration_us,
            channel,
            speed,
            power,
        },
    ))
}
