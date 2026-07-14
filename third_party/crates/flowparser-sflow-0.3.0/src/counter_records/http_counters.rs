use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HttpCounters {
    pub method_option_count: u32,
    pub method_get_count: u32,
    pub method_head_count: u32,
    pub method_post_count: u32,
    pub method_put_count: u32,
    pub method_delete_count: u32,
    pub method_trace_count: u32,
    pub method_connect_count: u32,
    pub method_other_count: u32,
    pub status_1xx_count: u32,
    pub status_2xx_count: u32,
    pub status_3xx_count: u32,
    pub status_4xx_count: u32,
    pub status_5xx_count: u32,
    pub status_other_count: u32,
}

pub(crate) fn parse_http_counters(input: &[u8]) -> IResult<&[u8], HttpCounters> {
    let (input, method_option_count) = be_u32(input)?;
    let (input, method_get_count) = be_u32(input)?;
    let (input, method_head_count) = be_u32(input)?;
    let (input, method_post_count) = be_u32(input)?;
    let (input, method_put_count) = be_u32(input)?;
    let (input, method_delete_count) = be_u32(input)?;
    let (input, method_trace_count) = be_u32(input)?;
    let (input, method_connect_count) = be_u32(input)?;
    let (input, method_other_count) = be_u32(input)?;
    let (input, status_1xx_count) = be_u32(input)?;
    let (input, status_2xx_count) = be_u32(input)?;
    let (input, status_3xx_count) = be_u32(input)?;
    let (input, status_4xx_count) = be_u32(input)?;
    let (input, status_5xx_count) = be_u32(input)?;
    let (input, status_other_count) = be_u32(input)?;

    Ok((
        input,
        HttpCounters {
            method_option_count,
            method_get_count,
            method_head_count,
            method_post_count,
            method_put_count,
            method_delete_count,
            method_trace_count,
            method_connect_count,
            method_other_count,
            status_1xx_count,
            status_2xx_count,
            status_3xx_count,
            status_4xx_count,
            status_5xx_count,
            status_other_count,
        },
    ))
}
