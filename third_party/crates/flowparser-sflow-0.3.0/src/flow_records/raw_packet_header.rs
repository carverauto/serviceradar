use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RawPacketHeader {
    pub header_protocol: u32,
    pub frame_length: u32,
    pub stripped: u32,
    pub header_length: u32,
    pub header: Vec<u8>,
}

pub(crate) fn parse_raw_packet_header(input: &[u8]) -> IResult<&[u8], RawPacketHeader> {
    let (input, header_protocol) = be_u32(input)?;
    let (input, frame_length) = be_u32(input)?;
    let (input, stripped) = be_u32(input)?;
    let (input, header_length) = be_u32(input)?;
    let (input, header) = take(header_length as usize)(input)?;
    // Skip XDR padding to 4-byte boundary
    let padding = (4 - (header_length as usize % 4)) % 4;
    let (input, _) = take(padding)(input)?;

    Ok((
        input,
        RawPacketHeader {
            header_protocol,
            frame_length,
            stripped,
            header_length,
            header: header.to_vec(),
        },
    ))
}
