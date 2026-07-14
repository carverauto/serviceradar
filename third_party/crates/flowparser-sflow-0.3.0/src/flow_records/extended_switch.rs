use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedSwitch {
    pub src_vlan: u32,
    pub src_priority: u32,
    pub dst_vlan: u32,
    pub dst_priority: u32,
}

pub(crate) fn parse_extended_switch(input: &[u8]) -> IResult<&[u8], ExtendedSwitch> {
    let (input, src_vlan) = be_u32(input)?;
    let (input, src_priority) = be_u32(input)?;
    let (input, dst_vlan) = be_u32(input)?;
    let (input, dst_priority) = be_u32(input)?;

    Ok((
        input,
        ExtendedSwitch {
            src_vlan,
            src_priority,
            dst_vlan,
            dst_priority,
        },
    ))
}
