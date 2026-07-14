use nom::IResult;
use nom::number::complete::be_u64;
use serde::{Deserialize, Serialize};

/// Extended nanosecond-precision wall clock timestamp (enterprise=0, format=1043).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedTimestamp {
    /// Wall clock time in nanoseconds since Unix epoch (UTC).
    pub nanoseconds: u64,
}

pub(crate) fn parse_extended_timestamp(input: &[u8]) -> IResult<&[u8], ExtendedTimestamp> {
    let (input, nanoseconds) = be_u64(input)?;

    Ok((input, ExtendedTimestamp { nanoseconds }))
}
