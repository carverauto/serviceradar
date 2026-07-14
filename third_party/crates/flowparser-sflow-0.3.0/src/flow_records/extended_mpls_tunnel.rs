use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedMplsTunnel {
    pub tunnel_lsp_name: String,
    pub tunnel_id: u32,
    pub tunnel_cos: u32,
}

pub(crate) fn parse_extended_mpls_tunnel(input: &[u8]) -> IResult<&[u8], ExtendedMplsTunnel> {
    let (input, tunnel_lsp_name) = parse_sflow_string(input)?;
    let (input, tunnel_id) = be_u32(input)?;
    let (input, tunnel_cos) = be_u32(input)?;

    Ok((
        input,
        ExtendedMplsTunnel {
            tunnel_lsp_name,
            tunnel_id,
            tunnel_cos,
        },
    ))
}
