use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::counter_records::{CounterRecord, parse_counter_records};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CounterSample {
    pub sequence_number: u32,
    pub source_id_type: u32,
    pub source_id_index: u32,
    pub records: Vec<CounterRecord>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ExpandedCounterSample {
    pub sequence_number: u32,
    pub source_id_type: u32,
    pub source_id_index: u32,
    pub records: Vec<CounterRecord>,
}

pub(crate) fn parse_counter_sample(input: &[u8]) -> IResult<&[u8], CounterSample> {
    let (input, sequence_number) = be_u32(input)?;
    let (input, source_id) = be_u32(input)?;
    let source_id_type = source_id >> 24;
    let source_id_index = source_id & 0x00FF_FFFF;
    let (input, num_records) = be_u32(input)?;

    let (input, records) = parse_counter_records(input, num_records)?;

    Ok((
        input,
        CounterSample {
            sequence_number,
            source_id_type,
            source_id_index,
            records,
        },
    ))
}

pub(crate) fn parse_expanded_counter_sample(
    input: &[u8],
) -> IResult<&[u8], ExpandedCounterSample> {
    let (input, sequence_number) = be_u32(input)?;
    let (input, source_id_type) = be_u32(input)?;
    let (input, source_id_index) = be_u32(input)?;
    let (input, num_records) = be_u32(input)?;

    let (input, records) = parse_counter_records(input, num_records)?;

    Ok((
        input,
        ExpandedCounterSample {
            sequence_number,
            source_id_type,
            source_id_index,
            records,
        },
    ))
}
