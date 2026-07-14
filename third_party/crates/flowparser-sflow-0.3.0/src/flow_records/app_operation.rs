use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppOperation {
    pub context: String,
    pub status_descr: String,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub duration_us: u32,
    pub status: u32,
}

pub(crate) fn parse_app_operation(input: &[u8]) -> IResult<&[u8], AppOperation> {
    let (input, context) = parse_sflow_string(input)?;
    let (input, status_descr) = parse_sflow_string(input)?;
    let (input, req_bytes) = be_u64(input)?;
    let (input, resp_bytes) = be_u64(input)?;
    let (input, duration_us) = be_u32(input)?;
    let (input, status) = be_u32(input)?;

    Ok((
        input,
        AppOperation {
            context,
            status_descr,
            req_bytes,
            resp_bytes,
            duration_us,
            status,
        },
    ))
}
