use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedProxySocketIpv4 {
    pub protocol: u32,
    pub local_ip: Ipv4Addr,
    pub remote_ip: Ipv4Addr,
    pub local_port: u32,
    pub remote_port: u32,
}

pub(crate) fn parse_extended_proxy_socket_ipv4(
    input: &[u8],
) -> IResult<&[u8], ExtendedProxySocketIpv4> {
    let (input, protocol) = be_u32(input)?;
    let (input, local_ip_raw) = be_u32(input)?;
    let (input, remote_ip_raw) = be_u32(input)?;
    let (input, local_port) = be_u32(input)?;
    let (input, remote_port) = be_u32(input)?;

    Ok((
        input,
        ExtendedProxySocketIpv4 {
            protocol,
            local_ip: Ipv4Addr::from(local_ip_raw),
            remote_ip: Ipv4Addr::from(remote_ip_raw),
            local_port,
            remote_port,
        },
    ))
}
