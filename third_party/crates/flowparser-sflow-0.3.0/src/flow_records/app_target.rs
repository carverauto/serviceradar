use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

/// Application target (enterprise=0, format=2205).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppTarget {
    pub actor: String,
}

pub(crate) fn parse_app_target(input: &[u8]) -> IResult<&[u8], AppTarget> {
    let (input, actor) = parse_sflow_string(input)?;

    Ok((input, AppTarget { actor }))
}
