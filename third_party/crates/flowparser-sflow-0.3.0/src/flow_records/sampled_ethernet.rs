use mac_address::MacAddress;
use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SampledEthernet {
    pub length: u32,
    pub src_mac: MacAddress,
    pub dst_mac: MacAddress,
    pub eth_type: u32,
}

fn parse_mac(input: &[u8]) -> IResult<&[u8], MacAddress> {
    if input.len() < 8 {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Eof,
        )));
    }
    // sFlow pads MAC addresses to 8 bytes (6 bytes MAC + 2 bytes padding)
    let bytes: [u8; 6] = [input[0], input[1], input[2], input[3], input[4], input[5]];
    Ok((&input[8..], MacAddress::new(bytes)))
}

pub(crate) fn parse_sampled_ethernet(input: &[u8]) -> IResult<&[u8], SampledEthernet> {
    // sFlow sampled ethernet: length(4) + src_mac(8) + dst_mac(8) + eth_type(4)
    let (input, length) = be_u32(input)?;
    let (input, src_mac) = parse_mac(input)?;
    let (input, dst_mac) = parse_mac(input)?;
    let (input, eth_type) = be_u32(input)?;

    Ok((
        input,
        SampledEthernet {
            length,
            src_mac,
            dst_mac,
            eth_type,
        },
    ))
}
