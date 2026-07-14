use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Virtual domain state from libvirt's virDomainState.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum VirtDomainState {
    NoState,
    Running,
    Blocked,
    Paused,
    Shutdown,
    Shutoff,
    Crashed,
    PmSuspended,
    Unrecognized(u32),
}

impl From<u32> for VirtDomainState {
    fn from(v: u32) -> Self {
        match v {
            0 => VirtDomainState::NoState,
            1 => VirtDomainState::Running,
            2 => VirtDomainState::Blocked,
            3 => VirtDomainState::Paused,
            4 => VirtDomainState::Shutdown,
            5 => VirtDomainState::Shutoff,
            6 => VirtDomainState::Crashed,
            7 => VirtDomainState::PmSuspended,
            v => VirtDomainState::Unrecognized(v),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VirtCpu {
    /// Virtual domain state.
    pub state: VirtDomainState,
    /// CPU time consumed in milliseconds.
    pub cpu_time: u32,
    /// Number of virtual CPUs.
    pub nr_virt_cpu: u32,
}

pub(crate) fn parse_virt_cpu(input: &[u8]) -> IResult<&[u8], VirtCpu> {
    let (input, state) = be_u32(input)?;
    let (input, cpu_time) = be_u32(input)?;
    let (input, nr_virt_cpu) = be_u32(input)?;

    Ok((
        input,
        VirtCpu {
            state: VirtDomainState::from(state),
            cpu_time,
            nr_virt_cpu,
        },
    ))
}
