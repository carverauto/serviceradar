use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VirtNetIo {
    pub rx_bytes: u64,
    pub rx_packets: u32,
    pub rx_errs: u32,
    pub rx_drop: u32,
    pub tx_bytes: u64,
    pub tx_packets: u32,
    pub tx_errs: u32,
    pub tx_drop: u32,
}

pub(crate) fn parse_virt_net_io(input: &[u8]) -> IResult<&[u8], VirtNetIo> {
    let (input, rx_bytes) = be_u64(input)?;
    let (input, rx_packets) = be_u32(input)?;
    let (input, rx_errs) = be_u32(input)?;
    let (input, rx_drop) = be_u32(input)?;
    let (input, tx_bytes) = be_u64(input)?;
    let (input, tx_packets) = be_u32(input)?;
    let (input, tx_errs) = be_u32(input)?;
    let (input, tx_drop) = be_u32(input)?;

    Ok((
        input,
        VirtNetIo {
            rx_bytes,
            rx_packets,
            rx_errs,
            rx_drop,
            tx_bytes,
            tx_packets,
            tx_errs,
            tx_drop,
        },
    ))
}
