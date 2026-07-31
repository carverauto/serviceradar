use crate::*;

///  Laxly identified payload of an link layer packet (potentially incomplete).
///
/// To check if the payload is complete check the `incomplete` field.
#[derive(Clone, Debug, Eq, PartialEq, Hash, PartialOrd, Ord)]
pub struct LaxEtherPayloadSlice<'a> {
    /// True if the length field in the link header (e.g. MACsec short length)
    /// indicates more data should be present but it was not (aka the packet
    /// data is cut off).
    pub incomplete: bool,

    /// Identifying content of the payload.
    pub ether_type: EtherType,

    /// Length field that was used to determine the length
    /// of the payload (e.g. MACsec "short length" field).
    pub len_source: LenSource,

    /// Payload
    pub payload: &'a [u8],
}
