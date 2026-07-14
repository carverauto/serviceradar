use nom::IResult;
use nom::number::complete::{be_f32, be_u32};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HostCpu {
    /// 1-minute load average.
    pub load_one: f32,
    /// 5-minute load average.
    pub load_five: f32,
    /// 15-minute load average.
    pub load_fifteen: f32,
    pub proc_run: u32,
    pub proc_total: u32,
    pub cpu_num: u32,
    pub cpu_speed: u32,
    pub uptime: u32,
    pub cpu_user: u32,
    pub cpu_nice: u32,
    pub cpu_system: u32,
    pub cpu_idle: u32,
    pub cpu_wio: u32,
    pub cpu_intr: u32,
    pub cpu_sintr: u32,
    pub interrupts: u32,
    pub contexts: u32,
}

pub(crate) fn parse_host_cpu(input: &[u8]) -> IResult<&[u8], HostCpu> {
    let (input, load_one) = be_f32(input)?;
    let (input, load_five) = be_f32(input)?;
    let (input, load_fifteen) = be_f32(input)?;
    let (input, proc_run) = be_u32(input)?;
    let (input, proc_total) = be_u32(input)?;
    let (input, cpu_num) = be_u32(input)?;
    let (input, cpu_speed) = be_u32(input)?;
    let (input, uptime) = be_u32(input)?;
    let (input, cpu_user) = be_u32(input)?;
    let (input, cpu_nice) = be_u32(input)?;
    let (input, cpu_system) = be_u32(input)?;
    let (input, cpu_idle) = be_u32(input)?;
    let (input, cpu_wio) = be_u32(input)?;
    let (input, cpu_intr) = be_u32(input)?;
    let (input, cpu_sintr) = be_u32(input)?;
    let (input, interrupts) = be_u32(input)?;
    let (input, contexts) = be_u32(input)?;

    Ok((
        input,
        HostCpu {
            load_one,
            load_five,
            load_fifteen,
            proc_run,
            proc_total,
            cpu_num,
            cpu_speed,
            uptime,
            cpu_user,
            cpu_nice,
            cpu_system,
            cpu_idle,
            cpu_wio,
            cpu_intr,
            cpu_sintr,
            interrupts,
            contexts,
        },
    ))
}
