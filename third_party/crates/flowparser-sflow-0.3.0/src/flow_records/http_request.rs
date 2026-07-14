use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HttpRequest {
    pub method: u32,
    pub protocol: u32,
    pub uri: String,
    pub host: String,
    pub referer: String,
    pub useragent: String,
    pub xff: String,
    pub authuser: String,
    pub mime_type: String,
    pub req_bytes: u64,
    pub resp_bytes: u64,
    pub duration_us: u32,
    pub status: u32,
}

pub(crate) fn parse_http_request(input: &[u8]) -> IResult<&[u8], HttpRequest> {
    let (input, method) = be_u32(input)?;
    let (input, protocol) = be_u32(input)?;
    let (input, uri) = parse_sflow_string(input)?;
    let (input, host) = parse_sflow_string(input)?;
    let (input, referer) = parse_sflow_string(input)?;
    let (input, useragent) = parse_sflow_string(input)?;
    let (input, xff) = parse_sflow_string(input)?;
    let (input, authuser) = parse_sflow_string(input)?;
    let (input, mime_type) = parse_sflow_string(input)?;
    let (input, req_bytes) = be_u64(input)?;
    let (input, resp_bytes) = be_u64(input)?;
    let (input, duration_us) = be_u32(input)?;
    let (input, status) = be_u32(input)?;

    Ok((
        input,
        HttpRequest {
            method,
            protocol,
            uri,
            host,
            referer,
            useragent,
            xff,
            authuser,
            mime_type,
            req_bytes,
            resp_bytes,
            duration_us,
            status,
        },
    ))
}
