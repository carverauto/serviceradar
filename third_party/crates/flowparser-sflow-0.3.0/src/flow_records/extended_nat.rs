use nom::IResult;
use serde::{Deserialize, Serialize};

use crate::datagram::{AddressType, parse_address};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExtendedNat {
    pub src_address: AddressType,
    pub dst_address: AddressType,
}

pub(crate) fn parse_extended_nat(input: &[u8]) -> IResult<&[u8], ExtendedNat> {
    let (input, src_address) = parse_address(input)?;
    let (input, dst_address) = parse_address(input)?;

    Ok((
        input,
        ExtendedNat {
            src_address,
            dst_address,
        },
    ))
}
