use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

/// Extended hardware trap data (enterprise=0, format=1041).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedHwTrap {
    pub group: String,
    pub trap: String,
}

pub(crate) fn parse_extended_hw_trap(input: &[u8]) -> IResult<&[u8], ExtendedHwTrap> {
    let (input, group) = parse_sflow_string(input)?;
    let (input, trap) = parse_sflow_string(input)?;

    Ok((input, ExtendedHwTrap { group, trap }))
}
