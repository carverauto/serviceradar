use nom::IResult;
use serde::{Deserialize, Serialize};

use crate::flow_records::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortName {
    pub name: String,
}

pub(crate) fn parse_port_name(input: &[u8]) -> IResult<&[u8], PortName> {
    let (input, name) = parse_sflow_string(input)?;

    Ok((input, PortName { name }))
}
