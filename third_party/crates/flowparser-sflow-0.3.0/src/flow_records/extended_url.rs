use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedUrl {
    pub direction: u32,
    pub url: String,
    pub host: String,
}

pub(crate) fn parse_extended_url(input: &[u8]) -> IResult<&[u8], ExtendedUrl> {
    let (input, direction) = be_u32(input)?;
    let (input, url) = parse_sflow_string(input)?;
    let (input, host) = parse_sflow_string(input)?;

    Ok((
        input,
        ExtendedUrl {
            direction,
            url,
            host,
        },
    ))
}
