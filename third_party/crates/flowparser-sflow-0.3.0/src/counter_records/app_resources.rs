use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppResources {
    pub user_time: u32,
    pub system_time: u32,
    pub mem_used: u64,
    pub mem_max: u64,
    pub fd_open: u32,
    pub fd_max: u32,
    pub conn_open: u32,
    pub conn_max: u32,
}

pub(crate) fn parse_app_resources(input: &[u8]) -> IResult<&[u8], AppResources> {
    let (input, user_time) = be_u32(input)?;
    let (input, system_time) = be_u32(input)?;
    let (input, mem_used) = be_u64(input)?;
    let (input, mem_max) = be_u64(input)?;
    let (input, fd_open) = be_u32(input)?;
    let (input, fd_max) = be_u32(input)?;
    let (input, conn_open) = be_u32(input)?;
    let (input, conn_max) = be_u32(input)?;

    Ok((
        input,
        AppResources {
            user_time,
            system_time,
            mem_used,
            mem_max,
            fd_open,
            fd_max,
            conn_open,
            conn_max,
        },
    ))
}
