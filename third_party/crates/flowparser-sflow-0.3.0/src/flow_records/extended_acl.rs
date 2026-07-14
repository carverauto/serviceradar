use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedAcl {
    pub number: u32,
    pub name: String,
    pub direction: u32,
}

pub(crate) fn parse_extended_acl(input: &[u8]) -> IResult<&[u8], ExtendedAcl> {
    let (input, number) = be_u32(input)?;
    let (input, name) = parse_sflow_string(input)?;
    let (input, direction) = be_u32(input)?;

    Ok((
        input,
        ExtendedAcl {
            number,
            name,
            direction,
        },
    ))
}
