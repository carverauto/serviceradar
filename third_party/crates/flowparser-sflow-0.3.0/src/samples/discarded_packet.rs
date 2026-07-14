use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::flow_records::{FlowRecord, parse_flow_records};

/// Discarded packet notification sample (enterprise=0, format=5).
///
/// Reports packets discarded by the switch, along with the reason
/// and flow records describing the discarded packet.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DiscardedPacket {
    pub sequence_number: u32,
    pub ds_class: u32,
    pub ds_index: u32,
    pub drops: u32,
    pub input: u32,
    pub output: u32,
    pub reason: u32,
    pub records: Vec<FlowRecord>,
}

pub(crate) fn parse_discarded_packet(input: &[u8]) -> IResult<&[u8], DiscardedPacket> {
    let (input, sequence_number) = be_u32(input)?;
    let (input, source_id) = be_u32(input)?;
    let ds_class = source_id >> 24;
    let ds_index = source_id & 0x00FF_FFFF;
    let (input, drops) = be_u32(input)?;
    let (input, input_if) = be_u32(input)?;
    let (input, output_if) = be_u32(input)?;
    let (input, reason) = be_u32(input)?;
    let (input, num_records) = be_u32(input)?;

    let (input, records) = parse_flow_records(input, num_records)?;

    Ok((
        input,
        DiscardedPacket {
            sequence_number,
            ds_class,
            ds_index,
            drops,
            input: input_if,
            output: output_if,
            reason,
            records,
        },
    ))
}
