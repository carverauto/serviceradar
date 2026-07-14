use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Extended80211Payload {
    pub cipher_suite: u32,
    pub data: Vec<u8>,
}

pub(crate) fn parse_extended_80211_payload(
    input: &[u8],
) -> IResult<&[u8], Extended80211Payload> {
    let (input, cipher_suite) = be_u32(input)?;
    let (input, length) = be_u32(input)?;
    let (input, bytes) = take(length as usize)(input)?;
    let padding = (4 - (length as usize % 4)) % 4;
    let (input, _) = take(padding)(input)?;

    Ok((
        input,
        Extended80211Payload {
            cipher_suite,
            data: bytes.to_vec(),
        },
    ))
}
