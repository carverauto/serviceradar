use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedMplsVc {
    pub vc_instance_name: String,
    pub vll_vc_id: u32,
    pub vc_label_cos: u32,
}

pub(crate) fn parse_extended_mpls_vc(input: &[u8]) -> IResult<&[u8], ExtendedMplsVc> {
    let (input, vc_instance_name) = parse_sflow_string(input)?;
    let (input, vll_vc_id) = be_u32(input)?;
    let (input, vc_label_cos) = be_u32(input)?;

    Ok((
        input,
        ExtendedMplsVc {
            vc_instance_name,
            vll_vc_id,
            vc_label_cos,
        },
    ))
}
