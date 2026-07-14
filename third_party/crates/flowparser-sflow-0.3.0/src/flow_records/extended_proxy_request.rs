use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedProxyRequest {
    pub uri: String,
    pub host: String,
}

pub(crate) fn parse_extended_proxy_request(
    input: &[u8],
) -> IResult<&[u8], ExtendedProxyRequest> {
    let (input, uri) = parse_sflow_string(input)?;
    let (input, host) = parse_sflow_string(input)?;

    Ok((input, ExtendedProxyRequest { uri, host }))
}
