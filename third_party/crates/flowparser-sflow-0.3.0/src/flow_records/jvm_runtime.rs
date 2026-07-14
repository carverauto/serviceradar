use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct JvmRuntime {
    pub vm_name: String,
    pub vm_vendor: String,
    pub vm_version: String,
}

pub(crate) fn parse_jvm_runtime(input: &[u8]) -> IResult<&[u8], JvmRuntime> {
    let (input, vm_name) = parse_sflow_string(input)?;
    let (input, vm_vendor) = parse_sflow_string(input)?;
    let (input, vm_version) = parse_sflow_string(input)?;

    Ok((
        input,
        JvmRuntime {
            vm_name,
            vm_vendor,
            vm_version,
        },
    ))
}
