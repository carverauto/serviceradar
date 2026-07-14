use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mib2UdpGroup {
    pub udp_in_datagrams: u32,
    pub udp_no_ports: u32,
    pub udp_in_errors: u32,
    pub udp_out_datagrams: u32,
    pub udp_rcvbuf_errors: u32,
    pub udp_sndbuf_errors: u32,
    pub udp_in_csum_errors: u32,
}

pub(crate) fn parse_mib2_udp_group(input: &[u8]) -> IResult<&[u8], Mib2UdpGroup> {
    let (input, udp_in_datagrams) = be_u32(input)?;
    let (input, udp_no_ports) = be_u32(input)?;
    let (input, udp_in_errors) = be_u32(input)?;
    let (input, udp_out_datagrams) = be_u32(input)?;
    let (input, udp_rcvbuf_errors) = be_u32(input)?;
    let (input, udp_sndbuf_errors) = be_u32(input)?;
    let (input, udp_in_csum_errors) = be_u32(input)?;

    Ok((
        input,
        Mib2UdpGroup {
            udp_in_datagrams,
            udp_no_ports,
            udp_in_errors,
            udp_out_datagrams,
            udp_rcvbuf_errors,
            udp_sndbuf_errors,
            udp_in_csum_errors,
        },
    ))
}
