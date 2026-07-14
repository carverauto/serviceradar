use nom::IResult;
use serde::{Deserialize, Serialize};

use super::parse_sflow_string;

/// Application initiator (enterprise=0, format=2204).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppInitiator {
    pub actor: String,
}

pub(crate) fn parse_app_initiator(input: &[u8]) -> IResult<&[u8], AppInitiator> {
    let (input, actor) = parse_sflow_string(input)?;

    Ok((input, AppInitiator { actor }))
}
