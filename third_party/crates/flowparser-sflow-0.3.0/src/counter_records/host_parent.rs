use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostParent {
    pub container_type: u32,
    pub container_index: u32,
}

pub(crate) fn parse_host_parent(input: &[u8]) -> IResult<&[u8], HostParent> {
    let (input, container_type) = be_u32(input)?;
    let (input, container_index) = be_u32(input)?;

    Ok((
        input,
        HostParent {
            container_type,
            container_index,
        },
    ))
}
