use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Extended TCP info (enterprise=0, format=2209).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedTcpInfo {
    /// Packet direction: 0=unknown, 1=received, 2=sent.
    pub direction: u32,
    pub snd_mss: u32,
    pub rcv_mss: u32,
    pub unacked: u32,
    pub lost: u32,
    pub retrans: u32,
    pub pmtu: u32,
    pub rtt: u32,
    pub rttvar: u32,
    pub snd_cwnd: u32,
    pub reordering: u32,
    pub min_rtt: u32,
}

pub(crate) fn parse_extended_tcp_info(input: &[u8]) -> IResult<&[u8], ExtendedTcpInfo> {
    let (input, direction) = be_u32(input)?;
    let (input, snd_mss) = be_u32(input)?;
    let (input, rcv_mss) = be_u32(input)?;
    let (input, unacked) = be_u32(input)?;
    let (input, lost) = be_u32(input)?;
    let (input, retrans) = be_u32(input)?;
    let (input, pmtu) = be_u32(input)?;
    let (input, rtt) = be_u32(input)?;
    let (input, rttvar) = be_u32(input)?;
    let (input, snd_cwnd) = be_u32(input)?;
    let (input, reordering) = be_u32(input)?;
    let (input, min_rtt) = be_u32(input)?;

    Ok((
        input,
        ExtendedTcpInfo {
            direction,
            snd_mss,
            rcv_mss,
            unacked,
            lost,
            retrans,
            pmtu,
            rtt,
            rttvar,
            snd_cwnd,
            reordering,
            min_rtt,
        },
    ))
}
