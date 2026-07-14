use mac_address::MacAddress;
use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LagPortStats {
    pub actor_system_id: MacAddress,
    pub partner_system_id: MacAddress,
    pub attachment_individual: u32,
    pub lacpdu_rx: u32,
    pub marker_pdu_rx: u32,
    pub marker_response_pdu_rx: u32,
    pub unknown_rx: u32,
    pub illegal_rx: u32,
    pub lacpdu_tx: u32,
    pub marker_pdu_tx: u32,
    pub marker_response_pdu_tx: u32,
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

pub(crate) fn parse_lag_port_stats(input: &[u8]) -> IResult<&[u8], LagPortStats> {
    let (input, actor_system_id) = parse_mac(input)?;
    let (input, partner_system_id) = parse_mac(input)?;
    let (input, attachment_individual) = be_u32(input)?;
    // 4 bytes of opaque state data (collector_state)
    let (input, _) = take(4u8)(input)?;
    let (input, lacpdu_rx) = be_u32(input)?;
    let (input, marker_pdu_rx) = be_u32(input)?;
    let (input, marker_response_pdu_rx) = be_u32(input)?;
    let (input, unknown_rx) = be_u32(input)?;
    let (input, illegal_rx) = be_u32(input)?;
    let (input, lacpdu_tx) = be_u32(input)?;
    let (input, marker_pdu_tx) = be_u32(input)?;
    let (input, marker_response_pdu_tx) = be_u32(input)?;

    Ok((
        input,
        LagPortStats {
            actor_system_id,
            partner_system_id,
            attachment_individual,
            lacpdu_rx,
            marker_pdu_rx,
            marker_response_pdu_rx,
            unknown_rx,
            illegal_rx,
            lacpdu_tx,
            marker_pdu_tx,
            marker_response_pdu_tx,
        },
    ))
}
