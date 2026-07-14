use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OfPort {
    pub datapath_id: u64,
    pub port_no: u32,
}

pub(crate) fn parse_of_port(input: &[u8]) -> IResult<&[u8], OfPort> {
    let (input, datapath_id) = be_u64(input)?;
    let (input, port_no) = be_u32(input)?;

    Ok((
        input,
        OfPort {
            datapath_id,
            port_no,
        },
    ))
}
