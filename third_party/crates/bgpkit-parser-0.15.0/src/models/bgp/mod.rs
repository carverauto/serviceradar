//! BGP messages and relevant structs.

pub mod attributes;
pub mod capabilities;
pub mod community;
pub mod elem;
pub mod error;
pub mod flowspec;
pub mod linkstate;
pub mod role;
pub mod tunnel_encap;

pub use attributes::*;
pub use community::*;
pub use elem::*;
pub use error::*;
pub use flowspec::*;
pub use linkstate::*;
pub use role::*;
pub use tunnel_encap::*;

use crate::models::network::*;
use capabilities::{
    AddPathCapability, BgpCapabilityType, BgpExtendedMessageCapability, BgpRoleCapability,
    ExtendedNextHopCapability, FourOctetAsCapability, GracefulRestartCapability,
    MultiprotocolExtensionsCapability, RouteRefreshCapability,
};
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::net::Ipv4Addr;

pub type BgpIdentifier = Ipv4Addr;

#[derive(Debug, TryFromPrimitive, IntoPrimitive, Copy, Clone, PartialEq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum BgpMessageType {
    OPEN = 1,
    UPDATE = 2,
    NOTIFICATION = 3,
    KEEPALIVE = 4,
}

// https://tools.ietf.org/html/rfc4271#section-4
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum BgpMessage {
    Open(BgpOpenMessage),
    Update(BgpUpdateMessage),
    Notification(BgpNotificationMessage),
    KeepAlive,
}

impl BgpMessage {
    pub const fn msg_type(&self) -> BgpMessageType {
        match self {
            BgpMessage::Open(_) => BgpMessageType::OPEN,
            BgpMessage::Update(_) => BgpMessageType::UPDATE,
            BgpMessage::Notification(_) => BgpMessageType::NOTIFICATION,
            BgpMessage::KeepAlive => BgpMessageType::KEEPALIVE,
        }
    }
}

/// BGP Open Message
///
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
///  +-+-+-+-+-+-+-+-+
///  |    Version    |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///  |     My Autonomous System      |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///  |           Hold Time           |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///  |                         BGP Identifier                        |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///  | Opt Parm Len  |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///  |                                                               |
///  |             Optional Parameters (variable)                    |
///  |                                                               |
///  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BgpOpenMessage {
    pub version: u8,
    pub asn: Asn,
    pub hold_time: u16,
    pub sender_ip: Ipv4Addr,
    pub extended_length: bool,
    pub opt_params: Vec<OptParam>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct OptParam {
    pub param_type: u8,
    pub param_len: u16,
    pub param_value: ParamValue,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum ParamValue {
    Raw(Vec<u8>),
    Capacities(Vec<Capability>),
}

/// BGP Capability.
///
/// - RFC3392: <https://datatracker.ietf.org/doc/html/rfc3392>
/// - Capability codes: <https://www.iana.org/assignments/capability-codes/capability-codes.xhtml#capability-codes-2>
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Capability {
    pub ty: BgpCapabilityType,
    pub value: CapabilityValue,
}

/// Parsed BGP capability values
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum CapabilityValue {
    /// Raw unparsed capability data
    Raw(Vec<u8>),
    /// Multiprotocol Extensions capability - RFC 2858, Section 7
    MultiprotocolExtensions(MultiprotocolExtensionsCapability),
    /// Route Refresh capability - RFC 2918
    RouteRefresh(RouteRefreshCapability),
    /// Extended Next Hop capability - RFC 8950, Section 3
    ExtendedNextHop(ExtendedNextHopCapability),
    /// Graceful Restart capability - RFC 4724
    GracefulRestart(GracefulRestartCapability),
    /// 4-octet AS number capability - RFC 6793
    FourOctetAs(FourOctetAsCapability),
    /// ADD-PATH capability - RFC 7911
    AddPath(AddPathCapability),
    /// BGP Role capability - RFC 9234
    BgpRole(BgpRoleCapability),
    /// BGP Extended Message capability - RFC 8654
    BgpExtendedMessage(BgpExtendedMessageCapability),
}

#[derive(Debug, Clone, PartialEq, Default, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
/// BGP Update Message.
///
/// Corresponding RFC section: <https://datatracker.ietf.org/doc/html/rfc4271#section-4.3>
pub struct BgpUpdateMessage {
    /// Withdrawn prefixes in this update message.
    ///
    /// **IMPORTANT:** Do **not** access this field directly in order to get all withdrawn prefixes.
    /// Some withdrawn prefixes may be present in the [`AttributeValue::MpUnreachNlri`] attribute,
    /// and will **not** be included here. Accessing this field directly may cause you to miss
    /// IPv6 or multi-protocol prefixes.
    ///
    /// Instead, use [`Elementor::bgp_update_to_elems`] to reliably extract all withdrawn prefixes from the update,
    /// or combine this field with prefixes found in the `MpUnreachNlri` attribute manually.
    ///
    /// See
    /// * RFC4271 Section 4.3: <https://datatracker.ietf.org/doc/html/rfc4271#section-4.3>
    /// * RFC4760 Section 4: <https://datatracker.ietf.org/doc/html/rfc4760#section-4>
    pub withdrawn_prefixes: Vec<NetworkPrefix>,

    /// BGP path attributes.
    pub attributes: Attributes,

    /// Network prefixes that are being advertised in this update message.
    ///
    /// **IMPORTANT:** Do **not** access this field directly in order to get all announced prefixes.
    /// Some advertised prefixes may be present in the [`AttributeValue::MpReachNlri`] attribute,
    /// and will **not** be included here. Accessing this field directly may cause you to miss
    /// IPv6 or multi-protocol prefixes.
    ///
    /// Instead, use [`Elementor::bgp_update_to_elems`] to reliably extract all announced prefixes from the update,
    /// or combine this field with prefixes found in the `MpReachNlri` attribute manually.
    ///
    /// See
    ///
    /// * RFC4271 Section 4.3: <https://datatracker.ietf.org/doc/html/rfc4271#section-4.3>
    /// * RFC4760 Section 3: <https://datatracker.ietf.org/doc/html/rfc4760#section-3>
    pub announced_prefixes: Vec<NetworkPrefix>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BgpNotificationMessage {
    pub error: BgpError,
    pub data: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_type() {
        let open = BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: Asn::new_32bit(1),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![],
        });
        assert_eq!(open.msg_type(), BgpMessageType::OPEN);

        let update = BgpMessage::Update(BgpUpdateMessage::default());
        assert_eq!(update.msg_type(), BgpMessageType::UPDATE);

        let notification = BgpMessage::Notification(BgpNotificationMessage {
            error: BgpError::Unknown(0, 0),
            data: vec![],
        });
        assert_eq!(notification.msg_type(), BgpMessageType::NOTIFICATION);

        let keepalive = BgpMessage::KeepAlive;
        assert_eq!(keepalive.msg_type(), BgpMessageType::KEEPALIVE);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        let open = BgpMessage::Open(BgpOpenMessage {
            version: 4,
            asn: Asn::new_32bit(1),
            hold_time: 180,
            sender_ip: Ipv4Addr::new(192, 0, 2, 1),
            extended_length: false,
            opt_params: vec![],
        });
        let serialized = serde_json::to_string(&open).unwrap();
        let deserialized: BgpMessage = serde_json::from_str(&serialized).unwrap();
        assert_eq!(open, deserialized);

        let update = BgpMessage::Update(BgpUpdateMessage::default());
        let serialized = serde_json::to_string(&update).unwrap();
        let deserialized: BgpMessage = serde_json::from_str(&serialized).unwrap();
        assert_eq!(update, deserialized);

        let notification = BgpMessage::Notification(BgpNotificationMessage {
            error: BgpError::Unknown(0, 0),
            data: vec![],
        });
        let serialized = serde_json::to_string(&notification).unwrap();
        let deserialized: BgpMessage = serde_json::from_str(&serialized).unwrap();
        assert_eq!(notification, deserialized);

        let keepalive = BgpMessage::KeepAlive;
        let serialized = serde_json::to_string(&keepalive).unwrap();
        let deserialized: BgpMessage = serde_json::from_str(&serialized).unwrap();
        assert_eq!(keepalive, deserialized);
    }
}
