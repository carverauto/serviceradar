use nom::IResult;
use nom::number::complete::be_u32;
use serde::{Deserialize, Serialize};

use crate::datagram::AddressType;

/// XenServer virtual interface (VIF) counter record (enterprise=4300, format=2).
///
/// This is an undocumented, proprietary structure emitted by Citrix XenServer
/// sFlow agents. It associates a virtual network interface with a VM via
/// its IP address and Xen domain ID.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct XenVif {
    /// Virtual interface index.
    pub vif_index: u32,
    /// IP address of the associated VM.
    pub vm_address: AddressType,
    /// Xen domain ID.
    pub domain_id: u32,
    /// Network or VIF index.
    pub network_index: u32,
    /// Status flags.
    pub flags: u32,
}

pub(crate) fn parse_xen_vif(input: &[u8]) -> IResult<&[u8], XenVif> {
    let (input, vif_index) = be_u32(input)?;
    let (input, addr_raw) = be_u32(input)?;
    let vm_address = AddressType::IPv4(std::net::Ipv4Addr::from(addr_raw));
    let (input, domain_id) = be_u32(input)?;
    let (input, network_index) = be_u32(input)?;
    let (input, flags) = be_u32(input)?;

    Ok((
        input,
        XenVif {
            vif_index,
            vm_address,
            domain_id,
            network_index,
            flags,
        },
    ))
}
