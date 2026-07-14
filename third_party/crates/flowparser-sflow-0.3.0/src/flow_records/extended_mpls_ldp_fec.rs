use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedMplsLdpFec {
    pub mpls_fec_addr_prefix_length: u32,
}

pub(crate) fn parse_extended_mpls_ldp_fec(input: &[u8]) -> IResult<&[u8], ExtendedMplsLdpFec> {
    let (input, mpls_fec_addr_prefix_length) = be_u32(input)?;

    Ok((
        input,
        ExtendedMplsLdpFec {
            mpls_fec_addr_prefix_length,
        },
    ))
}
