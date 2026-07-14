use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

/// Broadcom BST device buffer utilization (enterprise=4413, format=1).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BroadcomBstDeviceBuffers {
    /// Unicast buffer utilization percentage.
    pub uc_pc: u32,
    /// Multicast buffer utilization percentage.
    pub mc_pc: u32,
}

pub(crate) fn parse_broadcom_bst_device_buffers(
    input: &[u8],
) -> IResult<&[u8], BroadcomBstDeviceBuffers> {
    let (input, uc_pc) = be_u32(input)?;
    let (input, mc_pc) = be_u32(input)?;

    Ok((input, BroadcomBstDeviceBuffers { uc_pc, mc_pc }))
}

/// Broadcom BST port buffer utilization (enterprise=4413, format=2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BroadcomBstPortBuffers {
    pub ingress_uc_pc: u32,
    pub ingress_mc_pc: u32,
    pub egress_uc_pc: u32,
    pub egress_mc_pc: u32,
    pub egress_queue_uc_pc: [u32; 8],
    pub egress_queue_mc_pc: [u32; 8],
}

pub(crate) fn parse_broadcom_bst_port_buffers(
    input: &[u8],
) -> IResult<&[u8], BroadcomBstPortBuffers> {
    let (input, ingress_uc_pc) = be_u32(input)?;
    let (input, ingress_mc_pc) = be_u32(input)?;
    let (input, egress_uc_pc) = be_u32(input)?;
    let (input, egress_mc_pc) = be_u32(input)?;

    let mut egress_queue_uc_pc = [0u32; 8];
    let mut rest = input;
    for item in &mut egress_queue_uc_pc {
        let (r, val) = be_u32(rest)?;
        *item = val;
        rest = r;
    }

    let mut egress_queue_mc_pc = [0u32; 8];
    for item in &mut egress_queue_mc_pc {
        let (r, val) = be_u32(rest)?;
        *item = val;
        rest = r;
    }

    Ok((
        rest,
        BroadcomBstPortBuffers {
            ingress_uc_pc,
            ingress_mc_pc,
            egress_uc_pc,
            egress_mc_pc,
            egress_queue_uc_pc,
            egress_queue_mc_pc,
        },
    ))
}
