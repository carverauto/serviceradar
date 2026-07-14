use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// InfiniBand Local Routing Header (enterprise=0, format=1031).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedIbLrh {
    pub src_vl: u32,
    pub src_sl: u32,
    pub src_dlid: u32,
    pub src_slid: u32,
    pub src_lnh: u32,
    pub dst_vl: u32,
    pub dst_sl: u32,
    pub dst_dlid: u32,
    pub dst_slid: u32,
    pub dst_lnh: u32,
}

pub(crate) fn parse_extended_ib_lrh(input: &[u8]) -> IResult<&[u8], ExtendedIbLrh> {
    let (input, src_vl) = be_u32(input)?;
    let (input, src_sl) = be_u32(input)?;
    let (input, src_dlid) = be_u32(input)?;
    let (input, src_slid) = be_u32(input)?;
    let (input, src_lnh) = be_u32(input)?;
    let (input, dst_vl) = be_u32(input)?;
    let (input, dst_sl) = be_u32(input)?;
    let (input, dst_dlid) = be_u32(input)?;
    let (input, dst_slid) = be_u32(input)?;
    let (input, dst_lnh) = be_u32(input)?;

    Ok((
        input,
        ExtendedIbLrh {
            src_vl,
            src_sl,
            src_dlid,
            src_slid,
            src_lnh,
            dst_vl,
            dst_sl,
            dst_dlid,
            dst_slid,
            dst_lnh,
        },
    ))
}

/// InfiniBand Global Routing Header (enterprise=0, format=1032).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedIbGrh {
    pub flow_label: u32,
    pub tc: u32,
    pub s_gid: [u8; 16],
    pub d_gid: [u8; 16],
}

pub(crate) fn parse_extended_ib_grh(input: &[u8]) -> IResult<&[u8], ExtendedIbGrh> {
    let (input, flow_label) = be_u32(input)?;
    let (input, tc) = be_u32(input)?;
    let (input, s_gid_bytes) = take(16usize)(input)?;
    let (input, d_gid_bytes) = take(16usize)(input)?;

    let mut s_gid = [0u8; 16];
    s_gid.copy_from_slice(s_gid_bytes);
    let mut d_gid = [0u8; 16];
    d_gid.copy_from_slice(d_gid_bytes);

    Ok((
        input,
        ExtendedIbGrh {
            flow_label,
            tc,
            s_gid,
            d_gid,
        },
    ))
}

/// InfiniBand Base Transport Header (enterprise=0, format=1033).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedIbBrh {
    pub pky: u32,
    pub dst_qp: u32,
}

pub(crate) fn parse_extended_ib_brh(input: &[u8]) -> IResult<&[u8], ExtendedIbBrh> {
    let (input, pky) = be_u32(input)?;
    let (input, dst_qp) = be_u32(input)?;

    Ok((input, ExtendedIbBrh { pky, dst_qp }))
}
