use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::flow_records::{FlowRecord, parse_flow_records};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FlowSample {
    pub sequence_number: u32,
    pub source_id_type: u32,
    pub source_id_index: u32,
    pub sampling_rate: u32,
    pub sample_pool: u32,
    pub drops: u32,
    pub input: u32,
    pub output: u32,
    pub records: Vec<FlowRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExpandedFlowSample {
    pub sequence_number: u32,
    pub source_id_type: u32,
    pub source_id_index: u32,
    pub sampling_rate: u32,
    pub sample_pool: u32,
    pub drops: u32,
    pub input_format: u32,
    pub input_value: u32,
    pub output_format: u32,
    pub output_value: u32,
    pub records: Vec<FlowRecord>,
}

pub(crate) fn parse_flow_sample(input: &[u8]) -> IResult<&[u8], FlowSample> {
    let (input, sequence_number) = be_u32(input)?;
    let (input, source_id) = be_u32(input)?;
    let source_id_type = source_id >> 24;
    let source_id_index = source_id & 0x00FF_FFFF;
    let (input, sampling_rate) = be_u32(input)?;
    let (input, sample_pool) = be_u32(input)?;
    let (input, drops) = be_u32(input)?;
    let (input, input_if) = be_u32(input)?;
    let (input, output_if) = be_u32(input)?;
    let (input, num_records) = be_u32(input)?;

    let (input, records) = parse_flow_records(input, num_records)?;

    Ok((
        input,
        FlowSample {
            sequence_number,
            source_id_type,
            source_id_index,
            sampling_rate,
            sample_pool,
            drops,
            input: input_if,
            output: output_if,
            records,
        },
    ))
}

pub(crate) fn parse_expanded_flow_sample(input: &[u8]) -> IResult<&[u8], ExpandedFlowSample> {
    let (input, sequence_number) = be_u32(input)?;
    let (input, source_id_type) = be_u32(input)?;
    let (input, source_id_index) = be_u32(input)?;
    let (input, sampling_rate) = be_u32(input)?;
    let (input, sample_pool) = be_u32(input)?;
    let (input, drops) = be_u32(input)?;
    let (input, input_format) = be_u32(input)?;
    let (input, input_value) = be_u32(input)?;
    let (input, output_format) = be_u32(input)?;
    let (input, output_value) = be_u32(input)?;
    let (input, num_records) = be_u32(input)?;

    let (input, records) = parse_flow_records(input, num_records)?;

    Ok((
        input,
        ExpandedFlowSample {
            sequence_number,
            source_id_type,
            source_id_index,
            sampling_rate,
            sample_pool,
            drops,
            input_format,
            input_value,
            output_format,
            output_value,
            records,
        },
    ))
}
