use nom::IResult;
use nom::bytes::complete::take;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::flow_records::parse_sflow_string;

/// Machine architecture type from the sFlow host structures specification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum MachineType {
    Unknown,
    Other,
    X86,
    X86_64,
    Ia64,
    Sparc,
    Alpha,
    Mips,
    PowerPc,
    M68k,
    Arm,
    HpPa,
    S390,
    Unrecognized(u32),
}

impl From<u32> for MachineType {
    fn from(v: u32) -> Self {
        match v {
            0 => MachineType::Unknown,
            1 => MachineType::Other,
            2 => MachineType::X86,
            3 => MachineType::X86_64,
            4 => MachineType::Ia64,
            5 => MachineType::Sparc,
            6 => MachineType::Alpha,
            7 => MachineType::Mips,
            8 => MachineType::PowerPc,
            9 => MachineType::M68k,
            10 => MachineType::Arm,
            11 => MachineType::HpPa,
            12 => MachineType::S390,
            v => MachineType::Unrecognized(v),
        }
    }
}

/// Operating system name from the sFlow host structures specification.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OsName {
    Unknown,
    Other,
    Linux,
    Windows,
    Darwin,
    HpUx,
    Aix,
    DragonflyBsd,
    FreeBsd,
    NetBsd,
    OpenBsd,
    Osf,
    Solaris,
    Unrecognized(u32),
}

impl From<u32> for OsName {
    fn from(v: u32) -> Self {
        match v {
            0 => OsName::Unknown,
            1 => OsName::Other,
            2 => OsName::Linux,
            3 => OsName::Windows,
            4 => OsName::Darwin,
            5 => OsName::HpUx,
            6 => OsName::Aix,
            7 => OsName::DragonflyBsd,
            8 => OsName::FreeBsd,
            9 => OsName::NetBsd,
            10 => OsName::OpenBsd,
            11 => OsName::Osf,
            12 => OsName::Solaris,
            v => OsName::Unrecognized(v),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostDescr {
    pub hostname: String,
    pub uuid: Uuid,
    pub machine_type: MachineType,
    pub os_name: OsName,
    pub os_release: String,
}

pub(crate) fn parse_host_descr(input: &[u8]) -> IResult<&[u8], HostDescr> {
    let (input, hostname) = parse_sflow_string(input)?;
    let (input, uuid_bytes) = take(16u8)(input)?;
    let uuid = Uuid::from_slice(uuid_bytes).unwrap_or(Uuid::nil());
    let (input, machine_type) = be_u32(input)?;
    let (input, os_name) = be_u32(input)?;
    let (input, os_release) = parse_sflow_string(input)?;

    Ok((
        input,
        HostDescr {
            hostname,
            uuid,
            machine_type: MachineType::from(machine_type),
            os_name: OsName::from(os_name),
            os_release,
        },
    ))
}
