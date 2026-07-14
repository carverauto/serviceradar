use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mib2IpGroup {
    pub ip_forwarding: u32,
    pub ip_default_ttl: u32,
    pub ip_in_receives: u32,
    pub ip_in_hdr_errors: u32,
    pub ip_in_addr_errors: u32,
    pub ip_forw_datagrams: u32,
    pub ip_in_unknown_protos: u32,
    pub ip_in_discards: u32,
    pub ip_in_delivers: u32,
    pub ip_out_requests: u32,
    pub ip_out_discards: u32,
    pub ip_out_no_routes: u32,
    pub ip_reasm_timeout: u32,
    pub ip_reasm_reqds: u32,
    pub ip_reasm_oks: u32,
    pub ip_reasm_fails: u32,
    pub ip_frag_oks: u32,
    pub ip_frag_fails: u32,
    pub ip_frag_creates: u32,
}

pub(crate) fn parse_mib2_ip_group(input: &[u8]) -> IResult<&[u8], Mib2IpGroup> {
    let (input, ip_forwarding) = be_u32(input)?;
    let (input, ip_default_ttl) = be_u32(input)?;
    let (input, ip_in_receives) = be_u32(input)?;
    let (input, ip_in_hdr_errors) = be_u32(input)?;
    let (input, ip_in_addr_errors) = be_u32(input)?;
    let (input, ip_forw_datagrams) = be_u32(input)?;
    let (input, ip_in_unknown_protos) = be_u32(input)?;
    let (input, ip_in_discards) = be_u32(input)?;
    let (input, ip_in_delivers) = be_u32(input)?;
    let (input, ip_out_requests) = be_u32(input)?;
    let (input, ip_out_discards) = be_u32(input)?;
    let (input, ip_out_no_routes) = be_u32(input)?;
    let (input, ip_reasm_timeout) = be_u32(input)?;
    let (input, ip_reasm_reqds) = be_u32(input)?;
    let (input, ip_reasm_oks) = be_u32(input)?;
    let (input, ip_reasm_fails) = be_u32(input)?;
    let (input, ip_frag_oks) = be_u32(input)?;
    let (input, ip_frag_fails) = be_u32(input)?;
    let (input, ip_frag_creates) = be_u32(input)?;

    Ok((
        input,
        Mib2IpGroup {
            ip_forwarding,
            ip_default_ttl,
            ip_in_receives,
            ip_in_hdr_errors,
            ip_in_addr_errors,
            ip_forw_datagrams,
            ip_in_unknown_protos,
            ip_in_discards,
            ip_in_delivers,
            ip_out_requests,
            ip_out_discards,
            ip_out_no_routes,
            ip_reasm_timeout,
            ip_reasm_reqds,
            ip_reasm_oks,
            ip_reasm_fails,
            ip_frag_oks,
            ip_frag_fails,
            ip_frag_creates,
        },
    ))
}
