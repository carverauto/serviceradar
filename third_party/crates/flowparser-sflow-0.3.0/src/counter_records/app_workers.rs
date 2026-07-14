use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppWorkers {
    pub workers_active: u32,
    pub workers_idle: u32,
    pub workers_max: u32,
    pub req_delayed: u32,
    pub req_dropped: u32,
}

pub(crate) fn parse_app_workers(input: &[u8]) -> IResult<&[u8], AppWorkers> {
    let (input, workers_active) = be_u32(input)?;
    let (input, workers_idle) = be_u32(input)?;
    let (input, workers_max) = be_u32(input)?;
    let (input, req_delayed) = be_u32(input)?;
    let (input, req_dropped) = be_u32(input)?;

    Ok((
        input,
        AppWorkers {
            workers_active,
            workers_idle,
            workers_max,
            req_delayed,
            req_dropped,
        },
    ))
}
