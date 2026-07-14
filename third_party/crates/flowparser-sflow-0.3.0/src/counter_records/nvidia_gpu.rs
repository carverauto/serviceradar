use nom::IResult;
use nom::number::complete::{be_u32, be_u64};
use serde::{Deserialize, Serialize};

/// NVIDIA GPU counters via NVML (enterprise=5703, format=1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NvidiaGpu {
    pub device_count: u32,
    pub processes: u32,
    pub gpu_time: u32,
    pub mem_time: u32,
    pub mem_total: u64,
    pub mem_free: u64,
    pub ecc_errors: u32,
    pub energy: u32,
    pub temperature: u32,
    pub fan_speed: u32,
}

pub(crate) fn parse_nvidia_gpu(input: &[u8]) -> IResult<&[u8], NvidiaGpu> {
    let (input, device_count) = be_u32(input)?;
    let (input, processes) = be_u32(input)?;
    let (input, gpu_time) = be_u32(input)?;
    let (input, mem_time) = be_u32(input)?;
    let (input, mem_total) = be_u64(input)?;
    let (input, mem_free) = be_u64(input)?;
    let (input, ecc_errors) = be_u32(input)?;
    let (input, energy) = be_u32(input)?;
    let (input, temperature) = be_u32(input)?;
    let (input, fan_speed) = be_u32(input)?;

    Ok((
        input,
        NvidiaGpu {
            device_count,
            processes,
            gpu_time,
            mem_time,
            mem_total,
            mem_free,
            ecc_errors,
            energy,
            temperature,
            fan_speed,
        },
    ))
}
