use crate::{defrag::*, *};
use arrayvec::ArrayVec;

/// Values identifying a fragmented packet.
#[derive(Debug, Clone, Hash, Eq, PartialEq)]
pub struct IpFragId<CustomChannelId = ()>
where
    CustomChannelId: core::hash::Hash + Eq + PartialEq + Clone + Sized,
{
    /// VLAN id's of the original packets.
    pub vlan_ids: ArrayVec<VlanId, 3>,

    /// IP source & destination address & identifaction field.
    pub ip: IpFragVersionSpecId,

    /// IP number of the payload.
    pub payload_ip_number: IpNumber,

    /// Custom user defined channel identifier (can be used to differentiate packet
    /// sources if the normal ethernet packets identifier are not enough).
    pub channel_id: CustomChannelId,
}
