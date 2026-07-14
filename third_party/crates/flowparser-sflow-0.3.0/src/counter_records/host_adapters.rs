use mac_address::MacAddress;
use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostAdapter {
    pub if_index: u32,
    pub mac_addresses: Vec<MacAddress>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostAdapters {
    pub adapters: Vec<HostAdapter>,
}

fn parse_mac(input: &[u8]) -> IResult<&[u8], MacAddress> {
    if input.len() < 8 {
        return Err(nom::Err::Error(nom::error::Error::new(
            input,
            nom::error::ErrorKind::Eof,
        )));
    }
    let bytes: [u8; 6] = [input[0], input[1], input[2], input[3], input[4], input[5]];
    Ok((&input[8..], MacAddress::new(bytes)))
}

fn parse_host_adapter(input: &[u8]) -> IResult<&[u8], HostAdapter> {
    let (input, if_index) = be_u32(input)?;
    let (input, num_macs) = be_u32(input)?;
    // Each MAC is padded to 8 bytes in sFlow
    let cap = (num_macs as usize).min(input.len() / 8);
    let mut mac_addresses = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..num_macs {
        let (rest, mac) = parse_mac(input)?;
        mac_addresses.push(mac);
        input = rest;
    }

    Ok((
        input,
        HostAdapter {
            if_index,
            mac_addresses,
        },
    ))
}

pub(crate) fn parse_host_adapters(input: &[u8]) -> IResult<&[u8], HostAdapters> {
    let (input, num_adapters) = be_u32(input)?;
    // Each adapter needs at least 8 bytes (if_index + num_macs)
    let cap = (num_adapters as usize).min(input.len() / 8);
    let mut adapters = Vec::with_capacity(cap);
    let mut input = input;
    for _ in 0..num_adapters {
        let (rest, adapter) = parse_host_adapter(input)?;
        adapters.push(adapter);
        input = rest;
    }

    Ok((input, HostAdapters { adapters }))
}
