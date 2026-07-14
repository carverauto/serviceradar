use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedMplsFtn {
    pub mpls_ftn_descr: String,
    pub mpls_ftn_mask: u32,
}

pub(crate) fn parse_extended_mpls_ftn(input: &[u8]) -> IResult<&[u8], ExtendedMplsFtn> {
    let (input, mpls_ftn_descr) = parse_sflow_string(input)?;
    let (input, mpls_ftn_mask) = be_u32(input)?;

    Ok((
        input,
        ExtendedMplsFtn {
            mpls_ftn_descr,
            mpls_ftn_mask,
        },
    ))
}
