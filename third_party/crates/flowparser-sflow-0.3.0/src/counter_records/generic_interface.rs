use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GenericInterface {
    pub if_index: u32,
    pub if_type: u32,
    pub if_speed: u64,
    pub if_direction: u32,
    pub if_status: u32,
    pub if_in_octets: u64,
    pub if_in_ucast_pkts: u32,
    pub if_in_multicast_pkts: u32,
    pub if_in_broadcast_pkts: u32,
    pub if_in_discards: u32,
    pub if_in_errors: u32,
    pub if_in_unknown_protos: u32,
    pub if_out_octets: u64,
    pub if_out_ucast_pkts: u32,
    pub if_out_multicast_pkts: u32,
    pub if_out_broadcast_pkts: u32,
    pub if_out_discards: u32,
    pub if_out_errors: u32,
    pub if_promiscuous_mode: u32,
}

pub(crate) fn parse_generic_interface(input: &[u8]) -> IResult<&[u8], GenericInterface> {
    let (input, if_index) = be_u32(input)?;
    let (input, if_type) = be_u32(input)?;
    let (input, if_speed) = be_u64(input)?;
    let (input, if_direction) = be_u32(input)?;
    let (input, if_status) = be_u32(input)?;
    let (input, if_in_octets) = be_u64(input)?;
    let (input, if_in_ucast_pkts) = be_u32(input)?;
    let (input, if_in_multicast_pkts) = be_u32(input)?;
    let (input, if_in_broadcast_pkts) = be_u32(input)?;
    let (input, if_in_discards) = be_u32(input)?;
    let (input, if_in_errors) = be_u32(input)?;
    let (input, if_in_unknown_protos) = be_u32(input)?;
    let (input, if_out_octets) = be_u64(input)?;
    let (input, if_out_ucast_pkts) = be_u32(input)?;
    let (input, if_out_multicast_pkts) = be_u32(input)?;
    let (input, if_out_broadcast_pkts) = be_u32(input)?;
    let (input, if_out_discards) = be_u32(input)?;
    let (input, if_out_errors) = be_u32(input)?;
    let (input, if_promiscuous_mode) = be_u32(input)?;

    Ok((
        input,
        GenericInterface {
            if_index,
            if_type,
            if_speed,
            if_direction,
            if_status,
            if_in_octets,
            if_in_ucast_pkts,
            if_in_multicast_pkts,
            if_in_broadcast_pkts,
            if_in_discards,
            if_in_errors,
            if_in_unknown_protos,
            if_out_octets,
            if_out_ucast_pkts,
            if_out_multicast_pkts,
            if_out_broadcast_pkts,
            if_out_discards,
            if_out_errors,
            if_promiscuous_mode,
        },
    ))
}
