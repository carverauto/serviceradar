use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

/// Application parent context (enterprise=0, format=2203).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppParentContext {
    pub application: String,
    pub operation: String,
    pub attributes: String,
}

pub(crate) fn parse_app_parent_context(input: &[u8]) -> IResult<&[u8], AppParentContext> {
    let (input, application) = parse_sflow_string(input)?;
    let (input, operation) = parse_sflow_string(input)?;
    let (input, attributes) = parse_sflow_string(input)?;

    Ok((
        input,
        AppParentContext {
            application,
            operation,
            attributes,
        },
    ))
}
