use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Processor {
    pub cpu_5s: u32,
    pub cpu_1m: u32,
    pub cpu_5m: u32,
    pub total_memory: u64,
    pub free_memory: u64,
}

pub(crate) fn parse_processor(input: &[u8]) -> IResult<&[u8], Processor> {
    let (input, cpu_5s) = be_u32(input)?;
    let (input, cpu_1m) = be_u32(input)?;
    let (input, cpu_5m) = be_u32(input)?;
    let (input, total_memory) = be_u64(input)?;
    let (input, free_memory) = be_u64(input)?;

    Ok((
        input,
        Processor {
            cpu_5s,
            cpu_1m,
            cpu_5m,
            total_memory,
            free_memory,
        },
    ))
}
