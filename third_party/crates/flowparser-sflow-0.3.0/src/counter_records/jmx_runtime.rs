use nom::IResult;
use serde::{Deserialize, Serialize};

use crate::flow_records::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JmxRuntime {
    pub vm_name: String,
    pub vm_vendor: String,
    pub vm_version: String,
}

pub(crate) fn parse_jmx_runtime(input: &[u8]) -> IResult<&[u8], JmxRuntime> {
    let (input, vm_name) = parse_sflow_string(input)?;
    let (input, vm_vendor) = parse_sflow_string(input)?;
    let (input, vm_version) = parse_sflow_string(input)?;

    Ok((
        input,
        JmxRuntime {
            vm_name,
            vm_vendor,
            vm_version,
        },
    ))
}
