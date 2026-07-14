//! MRT message and relevant structs.

pub mod bgp4mp;
pub mod table_dump;
pub mod table_dump_v2;

pub use bgp4mp::*;
use num_enum::{IntoPrimitive, TryFromPrimitive};
use std::fmt::{Display, Formatter};
pub use table_dump::*;
pub use table_dump_v2::*;

/// MrtRecord is a wrapper struct that contains a header and a message.
///
/// A MRT record is constructed as the following:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                      Header... (variable)                     |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                      Message... (variable)
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// See [CommonHeader] for the content in header, and [MrtMessage] for the
/// message format.
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MrtRecord {
    pub common_header: CommonHeader,
    pub message: MrtMessage,
}

/// MRT common header.
///
/// A CommonHeader ([RFC6396 section 2][header-link]) is constructed as the following:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Timestamp                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |             Type              |            Subtype            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                             Length                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// Or with extended timestamp:
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                           Timestamp                           |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |             Type              |            Subtype            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                             Length                            |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                      Microsecond Timestamp                    |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// The headers include the following:
/// - timestamp: 32 bits
/// - entry_type: [EntryType] enum
/// - entry_subtype: entry subtype
/// - length: length of the message in octets
/// - (`ET` type only) microsecond_timestamp: microsecond part of the timestamp.
///   only applicable to the MRT message type with `_ET` suffix, such as
///   `BGP4MP_ET`
///
/// [header-link]: https://datatracker.ietf.org/doc/html/rfc6396#section-2
#[derive(Debug, Copy, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct CommonHeader {
    pub timestamp: u32,
    pub microsecond_timestamp: Option<u32>,
    pub entry_type: EntryType,
    pub entry_subtype: u16,
    pub length: u32,
}

impl PartialEq for CommonHeader {
    fn eq(&self, other: &Self) -> bool {
        self.timestamp == other.timestamp
            && self.microsecond_timestamp == other.microsecond_timestamp
            && self.entry_type == other.entry_type
            && self.entry_subtype == other.entry_subtype
        // && self.length == other.length
        // relax the length check as it might be different due to incorrect encoding
    }
}

impl Display for CommonHeader {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let ts = match self.microsecond_timestamp {
            Some(us) => format!("{}.{:06}", self.timestamp, us),
            None => self.timestamp.to_string(),
        };
        write!(
            f,
            "MRT|{}|{:?}|{}|{}",
            ts, self.entry_type, self.entry_subtype, self.length
        )
    }
}

impl Display for MrtRecord {
    /// Formats the MRT record in a debug-friendly format.
    ///
    /// The format is: `MRT|<timestamp>|<type>|<subtype>|<message_summary>`
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let ts = match self.common_header.microsecond_timestamp {
            Some(us) => format!("{}.{:06}", self.common_header.timestamp, us),
            None => self.common_header.timestamp.to_string(),
        };
        write!(
            f,
            "MRT|{}|{:?}|{}|{}",
            ts, self.common_header.entry_type, self.common_header.entry_subtype, self.message
        )
    }
}

impl Display for MrtMessage {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            MrtMessage::TableDumpMessage(msg) => {
                write!(f, "TABLE_DUMP|{}|{}", msg.prefix, msg.peer_ip)
            }
            MrtMessage::TableDumpV2Message(msg) => match msg {
                TableDumpV2Message::PeerIndexTable(pit) => {
                    write!(f, "PEER_INDEX_TABLE|{}", pit.id_peer_map.len())
                }
                TableDumpV2Message::RibAfi(rib) => {
                    write!(
                        f,
                        "RIB|{:?}|{}|{} entries",
                        rib.rib_type,
                        rib.prefix,
                        rib.rib_entries.len()
                    )
                }
                TableDumpV2Message::RibGeneric(rib) => {
                    write!(
                        f,
                        "RIB_GENERIC|AFI {:?}|SAFI {:?}|{} entries",
                        rib.afi,
                        rib.safi,
                        rib.rib_entries.len()
                    )
                }
                TableDumpV2Message::GeoPeerTable(gpt) => {
                    write!(f, "GEO_PEER_TABLE|{} peers", gpt.geo_peers.len())
                }
            },
            MrtMessage::Bgp4Mp(bgp4mp) => match bgp4mp {
                Bgp4MpEnum::StateChange(sc) => {
                    write!(
                        f,
                        "STATE_CHANGE|{}|{}|{:?}->{:?}",
                        sc.peer_ip, sc.peer_asn, sc.old_state, sc.new_state
                    )
                }
                Bgp4MpEnum::Message(msg) => {
                    let msg_type = match &msg.bgp_message {
                        crate::models::BgpMessage::Open(_) => "OPEN",
                        crate::models::BgpMessage::Update(_) => "UPDATE",
                        crate::models::BgpMessage::Notification(_) => "NOTIFICATION",
                        crate::models::BgpMessage::KeepAlive => "KEEPALIVE",
                    };
                    write!(f, "BGP4MP|{}|{}|{}", msg.peer_ip, msg.peer_asn, msg_type)
                }
            },
        }
    }
}

#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum MrtMessage {
    TableDumpMessage(TableDumpMessage),
    TableDumpV2Message(TableDumpV2Message),
    Bgp4Mp(Bgp4MpEnum),
}

/// MRT entry type.
///
/// EntryType indicates the type of the current MRT record. Type 0 to 10 are deprecated.
///
/// Excerpt from [RFC6396 section 4](https://datatracker.ietf.org/doc/html/rfc6396#section-4):
/// ```text
/// The following MRT Types are currently defined for the MRT format.
/// The MRT Types that contain the "_ET" suffix in their names identify
/// those types that use an Extended Timestamp MRT Header.  The Subtype
/// and Message fields in these types remain as defined for the MRT Types
/// of the same name without the "_ET" suffix.
///
///     11   OSPFv2
///     12   TABLE_DUMP
///     13   TABLE_DUMP_V2
///     16   BGP4MP
///     17   BGP4MP_ET
///     32   ISIS
///     33   ISIS_ET
///     48   OSPFv3
///     49   OSPFv3_ET
/// ```
#[derive(Debug, TryFromPrimitive, IntoPrimitive, Copy, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[allow(non_camel_case_types)]
#[repr(u16)]
pub enum EntryType {
    // START DEPRECATED
    NULL = 0,
    START = 1,
    DIE = 2,
    I_AM_DEAD = 3,
    PEER_DOWN = 4,
    BGP = 5,
    RIP = 6,
    IDRP = 7,
    RIPNG = 8,
    BGP4PLUS = 9,
    BGP4PLUS_01 = 10,
    // END DEPRECATED
    OSPFv2 = 11,
    TABLE_DUMP = 12,
    TABLE_DUMP_V2 = 13,
    BGP4MP = 16,
    BGP4MP_ET = 17,
    ISIS = 32,
    ISIS_ET = 33,
    OSPFv3 = 48,
    OSPFv3_ET = 49,
}

#[cfg(test)]
mod tests {

    #[test]
    fn test_mrt_record_display() {
        use super::*;
        use crate::models::Asn;
        use std::net::IpAddr;
        use std::str::FromStr;

        let mrt_record = MrtRecord {
            common_header: CommonHeader {
                timestamp: 1609459200,
                microsecond_timestamp: None,
                entry_type: EntryType::BGP4MP,
                entry_subtype: 0,
                length: 0,
            },
            message: MrtMessage::Bgp4Mp(Bgp4MpEnum::StateChange(Bgp4MpStateChange {
                msg_type: Bgp4MpType::StateChange,
                peer_asn: Asn::new_32bit(65000),
                local_asn: Asn::new_32bit(65001),
                interface_index: 1,
                peer_ip: IpAddr::from_str("10.0.0.1").unwrap(),
                local_addr: IpAddr::from_str("10.0.0.2").unwrap(),
                old_state: BgpState::Idle,
                new_state: BgpState::Connect,
            })),
        };

        let display = format!("{}", mrt_record);
        assert!(display.contains("1609459200"));
        assert!(display.contains("BGP4MP"));
        assert!(display.contains("STATE_CHANGE"));
        assert!(display.contains("10.0.0.1"));
        assert!(display.contains("65000"));
    }

    #[test]
    fn test_common_header_display() {
        use super::*;

        let header = CommonHeader {
            timestamp: 1609459200,
            microsecond_timestamp: Some(500000),
            entry_type: EntryType::BGP4MP_ET,
            entry_subtype: 4,
            length: 128,
        };

        let display = format!("{}", header);
        assert!(display.contains("1609459200.500000"));
        assert!(display.contains("BGP4MP_ET"));
        assert!(display.contains("128"));
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_entry_type_serialize_and_deserialize() {
        use super::*;
        let types = vec![
            EntryType::NULL,
            EntryType::START,
            EntryType::DIE,
            EntryType::I_AM_DEAD,
            EntryType::PEER_DOWN,
            EntryType::BGP,
            EntryType::RIP,
            EntryType::IDRP,
            EntryType::RIPNG,
            EntryType::BGP4PLUS,
            EntryType::BGP4PLUS_01,
            EntryType::OSPFv2,
            EntryType::TABLE_DUMP,
            EntryType::TABLE_DUMP_V2,
            EntryType::BGP4MP,
            EntryType::BGP4MP_ET,
            EntryType::ISIS,
            EntryType::ISIS_ET,
            EntryType::OSPFv3,
            EntryType::OSPFv3_ET,
        ];

        for entry_type in types {
            let serialized = serde_json::to_string(&entry_type).unwrap();
            let deserialized: EntryType = serde_json::from_str(&serialized).unwrap();

            assert_eq!(entry_type, deserialized);
        }
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serialization() {
        use super::*;
        use serde_json;
        use std::net::IpAddr;
        use std::str::FromStr;

        let mrt_record = MrtRecord {
            common_header: CommonHeader {
                timestamp: 0,
                microsecond_timestamp: None,
                entry_type: EntryType::BGP4MP,
                entry_subtype: 0,
                length: 0,
            },
            message: MrtMessage::Bgp4Mp(Bgp4MpEnum::StateChange(Bgp4MpStateChange {
                msg_type: Bgp4MpType::StateChange,
                peer_asn: crate::models::Asn::new_32bit(0),
                local_asn: crate::models::Asn::new_32bit(0),
                interface_index: 1,
                peer_ip: IpAddr::from_str("10.0.0.0").unwrap(),
                local_addr: IpAddr::from_str("10.0.0.0").unwrap(),
                old_state: BgpState::Idle,
                new_state: BgpState::Connect,
            })),
        };

        let serialized = serde_json::to_string(&mrt_record).unwrap();
        let deserialized: MrtRecord = serde_json::from_str(&serialized).unwrap();
        assert_eq!(mrt_record, deserialized);
    }
}
