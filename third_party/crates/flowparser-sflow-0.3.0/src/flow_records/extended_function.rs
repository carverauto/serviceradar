use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedFunction {
    pub symbol: String,
}

pub(crate) fn parse_extended_function(input: &[u8]) -> IResult<&[u8], ExtendedFunction> {
    let (input, symbol) = parse_sflow_string(input)?;

    Ok((input, ExtendedFunction { symbol }))
}
