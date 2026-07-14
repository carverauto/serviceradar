use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};
use std::net::Ipv6Addr;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SampledIpv6 {
    pub length: u32,
    pub protocol: u32,
    pub src_ip: Ipv6Addr,
    pub dst_ip: Ipv6Addr,
    pub src_port: u32,
    pub dst_port: u32,
    pub tcp_flags: u32,
    pub priority: u32,
}

fn parse_ipv6(input: &[u8]) -> IResult<&[u8], Ipv6Addr> {
    let (input, hi) = be_u64(input)?;
    let (input, lo) = be_u64(input)?;
    let mut octets = [0u8; 16];
    octets[..8].copy_from_slice(&hi.to_be_bytes());
    octets[8..].copy_from_slice(&lo.to_be_bytes());
    Ok((input, Ipv6Addr::from(octets)))
}

pub(crate) fn parse_sampled_ipv6(input: &[u8]) -> IResult<&[u8], SampledIpv6> {
    let (input, length) = be_u32(input)?;
    let (input, protocol) = be_u32(input)?;
    let (input, src_ip) = parse_ipv6(input)?;
    let (input, dst_ip) = parse_ipv6(input)?;
    let (input, src_port) = be_u32(input)?;
    let (input, dst_port) = be_u32(input)?;
    let (input, tcp_flags) = be_u32(input)?;
    let (input, priority) = be_u32(input)?;

    Ok((
        input,
        SampledIpv6 {
            length,
            protocol,
            src_ip,
            dst_ip,
            src_port,
            dst_port,
            tcp_flags,
            priority,
        },
    ))
}
