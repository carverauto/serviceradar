//! MRT BGP4MP structs
use crate::models::*;
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::net::IpAddr;

/// BGP states enum.
#[derive(Debug, TryFromPrimitive, IntoPrimitive, Copy, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum BgpState {
    Idle = 1,
    Connect = 2,
    Active = 3,
    OpenSent = 4,
    OpenConfirm = 5,
    Established = 6,
}

/// BGP4MP message types.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Bgp4MpEnum {
    StateChange(Bgp4MpStateChange),
    Message(Bgp4MpMessage),
}

impl Bgp4MpEnum {
    pub const fn msg_type(&self) -> Bgp4MpType {
        match self {
            Bgp4MpEnum::StateChange(x) => x.msg_type,
            Bgp4MpEnum::Message(x) => x.msg_type,
        }
    }
}

/// BGP4MP message subtypes.
#[derive(Debug, TryFromPrimitive, IntoPrimitive, Copy, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum Bgp4MpType {
    StateChange = 0,
    Message = 1,
    MessageAs4 = 4,
    StateChangeAs4 = 5,
    MessageLocal = 6,
    MessageAs4Local = 7,
    MessageAddpath = 8,
    MessageAs4Addpath = 9,
    MessageLocalAddpath = 10,
    MessageLocalAs4Addpath = 11,
}

/// BGP4MP state change message.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Bgp4MpStateChange {
    pub msg_type: Bgp4MpType,
    pub peer_asn: Asn,
    pub local_asn: Asn,
    pub interface_index: u16,
    pub peer_ip: IpAddr,
    pub local_addr: IpAddr,
    pub old_state: BgpState,
    pub new_state: BgpState,
}

/// BGP4MP message.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Bgp4MpMessage {
    pub msg_type: Bgp4MpType,
    pub peer_asn: Asn,
    pub local_asn: Asn,
    pub interface_index: u16,
    pub peer_ip: IpAddr,
    pub local_ip: IpAddr,
    pub bgp_message: BgpMessage,
}

impl Bgp4MpMessage {
    pub const fn is_local(&self) -> bool {
        matches!(
            self.msg_type,
            Bgp4MpType::MessageLocal
                | Bgp4MpType::MessageAs4Local
                | Bgp4MpType::MessageLocalAddpath
                | Bgp4MpType::MessageLocalAs4Addpath
        )
    }
}

pub const fn address_family(ip: &IpAddr) -> u16 {
    match ip {
        IpAddr::V4(_) => 1,
        IpAddr::V6(_) => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_msg_type() {
        let state_change = Bgp4MpEnum::StateChange(Bgp4MpStateChange {
            msg_type: Bgp4MpType::StateChange,
            peer_asn: Asn::new_32bit(0),
            local_asn: Asn::new_32bit(0),
            interface_index: 1,
            peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
            local_addr: IpAddr::from_str("10.0.0.1").unwrap(),
            old_state: BgpState::Idle,
            new_state: BgpState::Connect,
        });
        assert_eq!(state_change.msg_type(), Bgp4MpType::StateChange);

        let message = Bgp4MpEnum::Message(Bgp4MpMessage {
            msg_type: Bgp4MpType::Message,
            peer_asn: Asn::new_32bit(0),
            local_asn: Asn::new_32bit(0),
            interface_index: 1,
            peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
            local_ip: IpAddr::from_str("10.0.0.1").unwrap(),
            bgp_message: BgpMessage::Update(Default::default()),
        });
        assert_eq!(message.msg_type(), Bgp4MpType::Message);
    }

    #[test]
    fn test_is_local() {
        let mut message = Bgp4MpMessage {
            msg_type: Bgp4MpType::Message,
            peer_asn: Asn::new_32bit(0),
            local_asn: Asn::new_32bit(0),
            interface_index: 1,
            peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
            local_ip: IpAddr::from_str("10.0.0.1").unwrap(),
            bgp_message: BgpMessage::Update(Default::default()),
        };
        assert!(!message.is_local());

        message.msg_type = Bgp4MpType::MessageLocal;
        assert!(message.is_local());

        message.msg_type = Bgp4MpType::MessageAs4Local;
        assert!(message.is_local());

        message.msg_type = Bgp4MpType::MessageLocalAddpath;
        assert!(message.is_local());

        message.msg_type = Bgp4MpType::MessageLocalAs4Addpath;
        assert!(message.is_local());

        message.msg_type = Bgp4MpType::MessageAs4;
        assert!(!message.is_local());
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serialization() {
        let state_change = Bgp4MpEnum::StateChange(Bgp4MpStateChange {
            msg_type: Bgp4MpType::StateChange,
            peer_asn: Asn::new_32bit(0),
            local_asn: Asn::new_32bit(0),
            interface_index: 1,
            peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
            local_addr: IpAddr::from_str("10.0.0.1").unwrap(),
            old_state: BgpState::Idle,
            new_state: BgpState::Connect,
        });
        let serialized = serde_json::to_string(&state_change).unwrap();
        let deserialized: Bgp4MpEnum = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, state_change);

        let message = Bgp4MpEnum::Message(Bgp4MpMessage {
            msg_type: Bgp4MpType::Message,
            peer_asn: Asn::new_32bit(0),
            local_asn: Asn::new_32bit(0),
            interface_index: 1,
            peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
            local_ip: IpAddr::from_str("10.0.0.1").unwrap(),
            bgp_message: BgpMessage::Update(Default::default()),
        });
        let serialized = serde_json::to_string(&message).unwrap();
        let deserialized: Bgp4MpEnum = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, message);
    }
}
