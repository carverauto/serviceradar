use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Mib2TcpGroup {
    pub tcp_rto_algorithm: u32,
    pub tcp_rto_min: u32,
    pub tcp_rto_max: u32,
    pub tcp_max_conn: u32,
    pub tcp_active_opens: u32,
    pub tcp_passive_opens: u32,
    pub tcp_attempt_fails: u32,
    pub tcp_estab_resets: u32,
    pub tcp_curr_estab: u32,
    pub tcp_in_segs: u32,
    pub tcp_out_segs: u32,
    pub tcp_retrans_segs: u32,
    pub tcp_in_errs: u32,
    pub tcp_out_rsts: u32,
    pub tcp_in_csum_errs: u32,
}

pub(crate) fn parse_mib2_tcp_group(input: &[u8]) -> IResult<&[u8], Mib2TcpGroup> {
    let (input, tcp_rto_algorithm) = be_u32(input)?;
    let (input, tcp_rto_min) = be_u32(input)?;
    let (input, tcp_rto_max) = be_u32(input)?;
    let (input, tcp_max_conn) = be_u32(input)?;
    let (input, tcp_active_opens) = be_u32(input)?;
    let (input, tcp_passive_opens) = be_u32(input)?;
    let (input, tcp_attempt_fails) = be_u32(input)?;
    let (input, tcp_estab_resets) = be_u32(input)?;
    let (input, tcp_curr_estab) = be_u32(input)?;
    let (input, tcp_in_segs) = be_u32(input)?;
    let (input, tcp_out_segs) = be_u32(input)?;
    let (input, tcp_retrans_segs) = be_u32(input)?;
    let (input, tcp_in_errs) = be_u32(input)?;
    let (input, tcp_out_rsts) = be_u32(input)?;
    let (input, tcp_in_csum_errs) = be_u32(input)?;

    Ok((
        input,
        Mib2TcpGroup {
            tcp_rto_algorithm,
            tcp_rto_min,
            tcp_rto_max,
            tcp_max_conn,
            tcp_active_opens,
            tcp_passive_opens,
            tcp_attempt_fails,
            tcp_estab_resets,
            tcp_curr_estab,
            tcp_in_segs,
            tcp_out_segs,
            tcp_retrans_segs,
            tcp_in_errs,
            tcp_out_rsts,
            tcp_in_csum_errs,
        },
    ))
}
