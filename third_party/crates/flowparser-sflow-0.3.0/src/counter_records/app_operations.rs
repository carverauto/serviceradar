use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::flow_records::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppOperations {
    pub application: String,
    pub success: u32,
    pub other: u32,
    pub timeout: u32,
    pub internal_error: u32,
    pub bad_request: u32,
    pub forbidden: u32,
    pub too_large: u32,
    pub not_implemented: u32,
    pub not_found: u32,
    pub unavailable: u32,
    pub unauthorized: u32,
    pub status_ok: u32,
}

pub(crate) fn parse_app_operations(input: &[u8]) -> IResult<&[u8], AppOperations> {
    let (input, application) = parse_sflow_string(input)?;
    let (input, success) = be_u32(input)?;
    let (input, other) = be_u32(input)?;
    let (input, timeout) = be_u32(input)?;
    let (input, internal_error) = be_u32(input)?;
    let (input, bad_request) = be_u32(input)?;
    let (input, forbidden) = be_u32(input)?;
    let (input, too_large) = be_u32(input)?;
    let (input, not_implemented) = be_u32(input)?;
    let (input, not_found) = be_u32(input)?;
    let (input, unavailable) = be_u32(input)?;
    let (input, unauthorized) = be_u32(input)?;
    let (input, status_ok) = be_u32(input)?;

    Ok((
        input,
        AppOperations {
            application,
            success,
            other,
            timeout,
            internal_error,
            bad_request,
            forbidden,
            too_large,
            not_implemented,
            not_found,
            unavailable,
            unauthorized,
            status_ok,
        },
    ))
}
