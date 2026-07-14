use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostNetIo {
    pub bytes_in: u64,
    pub packets_in: u32,
    pub errs_in: u32,
    pub drops_in: u32,
    pub bytes_out: u64,
    pub packets_out: u32,
    pub errs_out: u32,
    pub drops_out: u32,
}

pub(crate) fn parse_host_net_io(input: &[u8]) -> IResult<&[u8], HostNetIo> {
    let (input, bytes_in) = be_u64(input)?;
    let (input, packets_in) = be_u32(input)?;
    let (input, errs_in) = be_u32(input)?;
    let (input, drops_in) = be_u32(input)?;
    let (input, bytes_out) = be_u64(input)?;
    let (input, packets_out) = be_u32(input)?;
    let (input, errs_out) = be_u32(input)?;
    let (input, drops_out) = be_u32(input)?;

    Ok((
        input,
        HostNetIo {
            bytes_in,
            packets_in,
            errs_in,
            drops_in,
            bytes_out,
            packets_out,
            errs_out,
            drops_out,
        },
    ))
}
