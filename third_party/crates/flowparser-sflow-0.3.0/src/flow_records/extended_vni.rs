use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedVniEgress {
    pub vni: u32,
}

pub(crate) fn parse_extended_vni_egress(input: &[u8]) -> IResult<&[u8], ExtendedVniEgress> {
    let (input, vni) = be_u32(input)?;

    Ok((input, ExtendedVniEgress { vni }))
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedVniIngress {
    pub vni: u32,
}

pub(crate) fn parse_extended_vni_ingress(input: &[u8]) -> IResult<&[u8], ExtendedVniIngress> {
    let (input, vni) = be_u32(input)?;

    Ok((input, ExtendedVniIngress { vni }))
}
