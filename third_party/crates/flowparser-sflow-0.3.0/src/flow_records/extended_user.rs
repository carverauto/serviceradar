use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedUser {
    pub src_charset: u32,
    pub src_user: String,
    pub dst_charset: u32,
    pub dst_user: String,
}

pub(crate) fn parse_extended_user(input: &[u8]) -> IResult<&[u8], ExtendedUser> {
    let (input, src_charset) = be_u32(input)?;
    let (input, src_user) = parse_sflow_string(input)?;
    let (input, dst_charset) = be_u32(input)?;
    let (input, dst_user) = parse_sflow_string(input)?;

    Ok((
        input,
        ExtendedUser {
            src_charset,
            src_user,
            dst_charset,
            dst_user,
        },
    ))
}
