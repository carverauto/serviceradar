use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};
use std::net::Ipv4Addr;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SampledIpv4 {
    pub length: u32,
    pub protocol: u32,
    pub src_ip: Ipv4Addr,
    pub dst_ip: Ipv4Addr,
    pub src_port: u32,
    pub dst_port: u32,
    pub tcp_flags: u32,
    pub tos: u32,
}

pub(crate) fn parse_sampled_ipv4(input: &[u8]) -> IResult<&[u8], SampledIpv4> {
    let (input, length) = be_u32(input)?;
    let (input, protocol) = be_u32(input)?;
    let (input, src_ip_raw) = be_u32(input)?;
    let (input, dst_ip_raw) = be_u32(input)?;
    let (input, src_port) = be_u32(input)?;
    let (input, dst_port) = be_u32(input)?;
    let (input, tcp_flags) = be_u32(input)?;
    let (input, tos) = be_u32(input)?;

    Ok((
        input,
        SampledIpv4 {
            length,
            protocol,
            src_ip: Ipv4Addr::from(src_ip_raw),
            dst_ip: Ipv4Addr::from(dst_ip_raw),
            src_port,
            dst_port,
            tcp_flags,
            tos,
        },
    ))
}
