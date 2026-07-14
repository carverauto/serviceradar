use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Vlan {
    pub vlan_id: u32,
    pub octets: u64,
    pub ucast_pkts: u32,
    pub multicast_pkts: u32,
    pub broadcast_pkts: u32,
    pub discards: u32,
}

pub(crate) fn parse_vlan(input: &[u8]) -> IResult<&[u8], Vlan> {
    let (input, vlan_id) = be_u32(input)?;
    let (input, octets) = be_u64(input)?;
    let (input, ucast_pkts) = be_u32(input)?;
    let (input, multicast_pkts) = be_u32(input)?;
    let (input, broadcast_pkts) = be_u32(input)?;
    let (input, discards) = be_u32(input)?;

    Ok((
        input,
        Vlan {
            vlan_id,
            octets,
            ucast_pkts,
            multicast_pkts,
            broadcast_pkts,
            discards,
        },
    ))
}
