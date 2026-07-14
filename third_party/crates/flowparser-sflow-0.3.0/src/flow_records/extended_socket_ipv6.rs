use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};
use std::net::Ipv6Addr;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedSocketIpv6 {
    pub protocol: u32,
    pub local_ip: Ipv6Addr,
    pub remote_ip: Ipv6Addr,
    pub local_port: u32,
    pub remote_port: u32,
}

fn parse_ipv6(input: &[u8]) -> IResult<&[u8], Ipv6Addr> {
    let (input, hi) = be_u64(input)?;
    let (input, lo) = be_u64(input)?;
    let mut octets = [0u8; 16];
    octets[..8].copy_from_slice(&hi.to_be_bytes());
    octets[8..].copy_from_slice(&lo.to_be_bytes());
    Ok((input, Ipv6Addr::from(octets)))
}

pub(crate) fn parse_extended_socket_ipv6(input: &[u8]) -> IResult<&[u8], ExtendedSocketIpv6> {
    let (input, protocol) = be_u32(input)?;
    let (input, local_ip) = parse_ipv6(input)?;
    let (input, remote_ip) = parse_ipv6(input)?;
    let (input, local_port) = be_u32(input)?;
    let (input, remote_port) = be_u32(input)?;

    Ok((
        input,
        ExtendedSocketIpv6 {
            protocol,
            local_ip,
            remote_ip,
            local_port,
            remote_port,
        },
    ))
}
