use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

/// Extended Linux kernel drop reason (enterprise=0, format=1042).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedLinuxDropReason {
    pub reason: String,
}

pub(crate) fn parse_extended_linux_drop_reason(
    input: &[u8],
) -> IResult<&[u8], ExtendedLinuxDropReason> {
    let (input, reason) = parse_sflow_string(input)?;

    Ok((input, ExtendedLinuxDropReason { reason }))
}
