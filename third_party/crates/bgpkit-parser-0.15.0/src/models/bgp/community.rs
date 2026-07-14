use crate::models::Asn;
use num_enum::{FromPrimitive, IntoPrimitive};
use std::fmt::{Display, Formatter};
use std::net::{Ipv4Addr, Ipv6Addr};

#[derive(Debug, PartialEq, Copy, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(untagged))]
pub enum MetaCommunity {
    Plain(Community),
    Extended(ExtendedCommunity),
    Ipv6Extended(Ipv6AddrExtCommunity),
    Large(LargeCommunity),
}

#[derive(Debug, PartialEq, Copy, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum Community {
    NoExport,
    NoAdvertise,
    NoExportSubConfed,
    Custom(Asn, u16),
}

/// Large community structure as defined in [RFC8092](https://datatracker.ietf.org/doc/html/rfc8092)
///
/// ## Display
///
/// Large community is displayed as `GLOBAL_ADMINISTRATOR:LOCAL_DATA_1:LOCAL_DATA_2`
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct LargeCommunity {
    pub global_admin: u32,
    pub local_data: [u32; 2],
}

impl LargeCommunity {
    pub fn new(global_admin: u32, local_data: [u32; 2]) -> LargeCommunity {
        LargeCommunity {
            global_admin,
            local_data,
        }
    }
}

/// Type definitions of extended communities
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum ExtendedCommunityType {
    // transitive types
    TransitiveTwoOctetAs = 0x00,
    TransitiveIpv4Addr = 0x01,
    TransitiveFourOctetAs = 0x02,
    TransitiveOpaque = 0x03,

    // non-transitive types
    NonTransitiveTwoOctetAs = 0x40,
    NonTransitiveIpv4Addr = 0x41,
    NonTransitiveFourOctetAs = 0x42,
    NonTransitiveOpaque = 0x43,
    // the rest are either draft or experimental
    #[num_enum(catch_all)]
    Unknown(u8),
}

/// Extended Communities.
///
/// ## Overview  
///
/// It is a 8-octet data that has flexible definition based on the types:
/// <https://datatracker.ietf.org/doc/html/rfc4360>
///
/// For more up-to-date definitions, see [IANA' website](https://www.iana.org/assignments/bgp-extended-communities/bgp-extended-communities.xhtml).
///
/// ```text
///    Each Extended Community is encoded as an 8-octet quantity, as
///    follows:
///
///       - Type Field  : 1 or 2 octets
///       - Value Field : Remaining octets
///
///        0                   1                   2                   3
///        0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///       |  Type high    |  Type low(*)  |                               |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+          Value                |
///       |                                                               |
///       +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
///
///       (*) Present for Extended types only, used for the Value field
///           otherwise.
/// ```
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum ExtendedCommunity {
    TransitiveTwoOctetAs(TwoOctetAsExtCommunity),
    TransitiveIpv4Addr(Ipv4AddrExtCommunity),
    TransitiveFourOctetAs(FourOctetAsExtCommunity),
    TransitiveOpaque(OpaqueExtCommunity),
    NonTransitiveTwoOctetAs(TwoOctetAsExtCommunity),
    NonTransitiveIpv4Addr(Ipv4AddrExtCommunity),
    NonTransitiveFourOctetAs(FourOctetAsExtCommunity),
    NonTransitiveOpaque(OpaqueExtCommunity),
    /// Flow-Spec Traffic Rate - RFC 8955
    FlowSpecTrafficRate(FlowSpecTrafficRate),
    /// Flow-Spec Traffic Action - RFC 8955  
    FlowSpecTrafficAction(FlowSpecTrafficAction),
    /// Flow-Spec Redirect - RFC 8955
    FlowSpecRedirect(TwoOctetAsExtCommunity),
    /// Flow-Spec Traffic Marking - RFC 8955
    FlowSpecTrafficMarking(FlowSpecTrafficMarking),
    Raw([u8; 8]),
}

impl ExtendedCommunity {
    pub const fn community_type(&self) -> ExtendedCommunityType {
        use ExtendedCommunityType::*;
        match self {
            ExtendedCommunity::TransitiveTwoOctetAs(_) => TransitiveTwoOctetAs,
            ExtendedCommunity::TransitiveIpv4Addr(_) => TransitiveIpv4Addr,
            ExtendedCommunity::TransitiveFourOctetAs(_) => TransitiveFourOctetAs,
            ExtendedCommunity::TransitiveOpaque(_) => TransitiveOpaque,
            ExtendedCommunity::NonTransitiveTwoOctetAs(_) => NonTransitiveTwoOctetAs,
            ExtendedCommunity::NonTransitiveIpv4Addr(_) => NonTransitiveIpv4Addr,
            ExtendedCommunity::NonTransitiveFourOctetAs(_) => NonTransitiveFourOctetAs,
            ExtendedCommunity::NonTransitiveOpaque(_) => NonTransitiveOpaque,
            ExtendedCommunity::FlowSpecTrafficRate(_) => NonTransitiveTwoOctetAs,
            ExtendedCommunity::FlowSpecTrafficAction(_) => NonTransitiveTwoOctetAs,
            ExtendedCommunity::FlowSpecRedirect(_) => NonTransitiveTwoOctetAs,
            ExtendedCommunity::FlowSpecTrafficMarking(_) => NonTransitiveTwoOctetAs,
            ExtendedCommunity::Raw(buffer) => Unknown(buffer[0]),
        }
    }
}

#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Ipv6AddrExtCommunity {
    pub community_type: ExtendedCommunityType,
    pub subtype: u8,
    // 16 octets
    pub global_admin: Ipv6Addr,
    // 2 octets
    pub local_admin: [u8; 2],
}

/// Two-Octet AS Specific Extended Community
///
/// <https://datatracker.ietf.org/doc/html/rfc4360#section-3.1>
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TwoOctetAsExtCommunity {
    pub subtype: u8,
    // 2 octet
    pub global_admin: Asn,
    // 4 octet
    pub local_admin: [u8; 4],
}

/// Four-Octet AS Specific Extended Community
///
/// <https://datatracker.ietf.org/doc/html/rfc5668#section-2>
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FourOctetAsExtCommunity {
    pub subtype: u8,
    // 4 octet
    pub global_admin: Asn,
    // 2 octet
    pub local_admin: [u8; 2],
}

/// IPv4 Address Specific Extended Community
///
/// <https://datatracker.ietf.org/doc/html/rfc4360#section-3.2>
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Ipv4AddrExtCommunity {
    pub subtype: u8,
    // 4 octet
    pub global_admin: Ipv4Addr,
    // 2 octet
    pub local_admin: [u8; 2],
}

/// Opaque Extended Community
///
/// <https://datatracker.ietf.org/doc/html/rfc4360#section-3.3>
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct OpaqueExtCommunity {
    pub subtype: u8,
    // 6 octet
    pub value: [u8; 6],
}

/// Flow-Spec Traffic Rate Extended Community
///
/// RFC 8955 - subtype 0x06
#[derive(Debug, Clone, Copy)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FlowSpecTrafficRate {
    /// AS Number (2 octets)
    pub as_number: u16,
    /// Rate in bytes per second (IEEE 754 single precision float)
    pub rate_bytes_per_sec: f32,
}

impl PartialEq for FlowSpecTrafficRate {
    fn eq(&self, other: &Self) -> bool {
        self.as_number == other.as_number
            && self.rate_bytes_per_sec.to_bits() == other.rate_bytes_per_sec.to_bits()
    }
}

impl Eq for FlowSpecTrafficRate {}

/// Flow-Spec Traffic Action Extended Community
///
/// RFC 8955 - subtype 0x07  
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FlowSpecTrafficAction {
    /// AS Number (2 octets)
    pub as_number: u16,
    /// Terminal action - stop processing additional flow-specs
    pub terminal: bool,
    /// Sample action - enable traffic sampling
    pub sample: bool,
}

/// Flow-Spec Traffic Marking Extended Community
///
/// RFC 8955 - subtype 0x09
#[derive(Debug, PartialEq, Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FlowSpecTrafficMarking {
    /// AS Number (2 octets)
    pub as_number: u16,
    /// DSCP value (6 bits)
    pub dscp: u8,
}

impl FlowSpecTrafficRate {
    /// Create a new traffic rate community
    pub fn new(as_number: u16, rate_bytes_per_sec: f32) -> Self {
        Self {
            as_number,
            rate_bytes_per_sec,
        }
    }

    /// Create a "discard all traffic" rate (rate = 0.0)
    pub fn discard(as_number: u16) -> Self {
        Self {
            as_number,
            rate_bytes_per_sec: 0.0,
        }
    }
}

impl FlowSpecTrafficAction {
    /// Create a new traffic action community
    pub fn new(as_number: u16, terminal: bool, sample: bool) -> Self {
        Self {
            as_number,
            terminal,
            sample,
        }
    }
}

impl FlowSpecTrafficMarking {
    /// Create a new traffic marking community
    pub fn new(as_number: u16, dscp: u8) -> Self {
        Self {
            as_number,
            dscp: dscp & 0x3F,
        } // Mask to 6 bits
    }
}

/////////////
// DISPLAY //
/////////////

struct ToHexString<'a>(&'a [u8]);

impl Display for ToHexString<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        for byte in self.0 {
            write!(f, "{byte:02X}")?;
        }
        Ok(())
    }
}

impl Display for Community {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Community::NoExport => write!(f, "no-export"),
            Community::NoAdvertise => write!(f, "no-advertise"),
            Community::NoExportSubConfed => write!(f, "no-export-sub-confed"),
            Community::Custom(asn, value) => write!(f, "{asn}:{value}"),
        }
    }
}

impl Display for LargeCommunity {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}:{}:{}",
            self.global_admin, self.local_data[0], self.local_data[1]
        )
    }
}

impl Display for ExtendedCommunity {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        let ec_type = u8::from(self.community_type());
        match self {
            ExtendedCommunity::TransitiveTwoOctetAs(ec)
            | ExtendedCommunity::NonTransitiveTwoOctetAs(ec) => {
                write!(
                    f,
                    "{}:{}:{}:{}",
                    ec_type,
                    ec.subtype,
                    ec.global_admin,
                    ToHexString(&ec.local_admin)
                )
            }
            ExtendedCommunity::TransitiveIpv4Addr(ec)
            | ExtendedCommunity::NonTransitiveIpv4Addr(ec) => {
                write!(
                    f,
                    "{}:{}:{}:{}",
                    ec_type,
                    ec.subtype,
                    ec.global_admin,
                    ToHexString(&ec.local_admin)
                )
            }
            ExtendedCommunity::TransitiveFourOctetAs(ec)
            | ExtendedCommunity::NonTransitiveFourOctetAs(ec) => {
                write!(
                    f,
                    "{}:{}:{}:{}",
                    ec_type,
                    ec.subtype,
                    ec.global_admin,
                    ToHexString(&ec.local_admin)
                )
            }
            ExtendedCommunity::TransitiveOpaque(ec)
            | ExtendedCommunity::NonTransitiveOpaque(ec) => {
                write!(f, "{}:{}:{}", ec_type, ec.subtype, ToHexString(&ec.value))
            }
            ExtendedCommunity::FlowSpecTrafficRate(rate) => {
                write!(
                    f,
                    "rate:{} bytes/sec (AS {})",
                    rate.rate_bytes_per_sec, rate.as_number
                )
            }
            ExtendedCommunity::FlowSpecTrafficAction(action) => {
                let mut flags = Vec::new();
                if action.terminal {
                    flags.push("terminal");
                }
                if action.sample {
                    flags.push("sample");
                }
                write!(f, "action:{} (AS {})", flags.join(","), action.as_number)
            }
            ExtendedCommunity::FlowSpecRedirect(redirect) => {
                write!(
                    f,
                    "redirect:AS{}:{}",
                    redirect.global_admin,
                    ToHexString(&redirect.local_admin)
                )
            }
            ExtendedCommunity::FlowSpecTrafficMarking(marking) => {
                write!(f, "mark:DSCP{} (AS {})", marking.dscp, marking.as_number)
            }
            ExtendedCommunity::Raw(ec) => {
                write!(f, "{}", ToHexString(ec))
            }
        }
    }
}

impl Display for Ipv6AddrExtCommunity {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}:{}:{}:{}",
            u8::from(self.community_type),
            self.subtype,
            self.global_admin,
            ToHexString(&self.local_admin)
        )
    }
}

impl Display for MetaCommunity {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            MetaCommunity::Plain(c) => write!(f, "{c}"),
            MetaCommunity::Extended(c) => write!(f, "{c}"),
            MetaCommunity::Large(c) => write!(f, "{c}"),
            MetaCommunity::Ipv6Extended(c) => write!(f, "{c}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_large_community_new() {
        let global_admin = 56;
        let local_data = [3, 4];
        let large_comm = LargeCommunity::new(global_admin, local_data);
        assert_eq!(large_comm.global_admin, global_admin);
        assert_eq!(large_comm.local_data, local_data);
    }

    #[test]
    fn test_extended_community_community_type() {
        let two_octet_as_ext_comm = TwoOctetAsExtCommunity {
            subtype: 0,
            global_admin: Asn::new_32bit(0),
            local_admin: [0; 4],
        };
        let extended_community = ExtendedCommunity::TransitiveTwoOctetAs(two_octet_as_ext_comm);
        assert_eq!(
            extended_community.community_type(),
            ExtendedCommunityType::TransitiveTwoOctetAs
        );
    }

    #[test]
    fn test_display_community() {
        assert_eq!(format!("{}", Community::NoExport), "no-export");
        assert_eq!(format!("{}", Community::NoAdvertise), "no-advertise");
        assert_eq!(
            format!("{}", Community::NoExportSubConfed),
            "no-export-sub-confed"
        );
        assert_eq!(
            format!("{}", Community::Custom(Asn::new_32bit(64512), 100)),
            "64512:100"
        );
    }

    #[test]
    fn test_display_large_community() {
        let large_community = LargeCommunity::new(1, [2, 3]);
        assert_eq!(format!("{large_community}"), "1:2:3");
    }

    #[test]
    fn test_display_extended_community() {
        let two_octet_as_ext_comm = TwoOctetAsExtCommunity {
            subtype: 0,
            global_admin: Asn::new_32bit(0),
            local_admin: [0; 4],
        };
        let extended_community = ExtendedCommunity::TransitiveTwoOctetAs(two_octet_as_ext_comm);
        assert_eq!(format!("{extended_community}"), "0:0:0:00000000");

        let two_octet_as_ext_comm = TwoOctetAsExtCommunity {
            subtype: 0,
            global_admin: Asn::new_32bit(0),
            local_admin: [0; 4],
        };
        let extended_community = ExtendedCommunity::NonTransitiveTwoOctetAs(two_octet_as_ext_comm);
        assert_eq!(format!("{extended_community}"), "64:0:0:00000000");

        let ipv4_ext_comm = Ipv4AddrExtCommunity {
            subtype: 1,
            global_admin: "192.168.1.1".parse().unwrap(),
            local_admin: [5, 6],
        };
        let extended_community = ExtendedCommunity::TransitiveIpv4Addr(ipv4_ext_comm);
        assert_eq!(format!("{extended_community}"), "1:1:192.168.1.1:0506");

        let ipv4_ext_comm = Ipv4AddrExtCommunity {
            subtype: 1,
            global_admin: "192.168.1.1".parse().unwrap(),
            local_admin: [5, 6],
        };
        let extended_community = ExtendedCommunity::NonTransitiveIpv4Addr(ipv4_ext_comm);
        assert_eq!(format!("{extended_community}"), "65:1:192.168.1.1:0506");

        let four_octet_as_ext_comm = FourOctetAsExtCommunity {
            subtype: 2,
            global_admin: Asn::new_32bit(64512),
            local_admin: [7, 8],
        };
        let extended_community = ExtendedCommunity::TransitiveFourOctetAs(four_octet_as_ext_comm);
        assert_eq!(format!("{extended_community}"), "2:2:64512:0708");

        let four_octet_as_ext_comm = FourOctetAsExtCommunity {
            subtype: 2,
            global_admin: Asn::new_32bit(64512),
            local_admin: [7, 8],
        };
        let extended_community =
            ExtendedCommunity::NonTransitiveFourOctetAs(four_octet_as_ext_comm);
        assert_eq!(format!("{extended_community}"), "66:2:64512:0708");

        let opaque_ext_comm = OpaqueExtCommunity {
            subtype: 3,
            value: [9, 10, 11, 12, 13, 14],
        };
        let extended_community = ExtendedCommunity::TransitiveOpaque(opaque_ext_comm);
        assert_eq!(format!("{extended_community}"), "3:3:090A0B0C0D0E");

        let opaque_ext_comm = OpaqueExtCommunity {
            subtype: 3,
            value: [9, 10, 11, 12, 13, 14],
        };
        let extended_community = ExtendedCommunity::NonTransitiveOpaque(opaque_ext_comm);
        assert_eq!(format!("{extended_community}"), "67:3:090A0B0C0D0E");

        let raw_ext_comm = [0, 1, 2, 3, 4, 5, 6, 7];
        let extended_community = ExtendedCommunity::Raw(raw_ext_comm);
        assert_eq!(format!("{extended_community}"), "0001020304050607");
    }

    #[test]
    fn test_display_ipv6_addr_ext_community() {
        let ipv6_addr_ext_comm = Ipv6AddrExtCommunity {
            community_type: ExtendedCommunityType::TransitiveTwoOctetAs,
            subtype: 0,
            global_admin: "2001:db8::8a2e:370:7334".parse().unwrap(),
            local_admin: [0, 1],
        };
        assert_eq!(
            format!("{ipv6_addr_ext_comm}"),
            "0:0:2001:db8::8a2e:370:7334:0001"
        );
    }

    #[test]
    fn test_display_meta_community() {
        let large_community = LargeCommunity::new(1, [2, 3]);
        let meta_community = MetaCommunity::Large(large_community);
        assert_eq!(format!("{meta_community}"), "1:2:3");
    }

    #[test]
    fn test_to_hex_string() {
        // Test empty array
        assert_eq!(format!("{}", ToHexString(&[])), "");

        // Test single byte
        assert_eq!(format!("{}", ToHexString(&[0x0A])), "0A");

        // Test multiple bytes
        assert_eq!(format!("{}", ToHexString(&[0x0A, 0x0B, 0x0C])), "0A0B0C");

        // Test zero byte
        assert_eq!(format!("{}", ToHexString(&[0x00])), "00");

        // Test byte with value > 0x0F (needs two hex digits)
        assert_eq!(format!("{}", ToHexString(&[0x10])), "10");

        // Test mixed bytes
        assert_eq!(
            format!("{}", ToHexString(&[0x00, 0x0F, 0x10, 0xFF])),
            "000F10FF"
        );
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        let meta_community = MetaCommunity::Large(LargeCommunity::new(1, [2, 3]));
        let serialized = serde_json::to_string(&meta_community).unwrap();
        let deserialized: MetaCommunity = serde_json::from_str(&serialized).unwrap();
        assert_eq!(meta_community, deserialized);

        let meta_community = MetaCommunity::Extended(ExtendedCommunity::TransitiveTwoOctetAs(
            TwoOctetAsExtCommunity {
                subtype: 0,
                global_admin: Asn::new_32bit(0),
                local_admin: [0; 4],
            },
        ));
        let serialized = serde_json::to_string(&meta_community).unwrap();
        let deserialized: MetaCommunity = serde_json::from_str(&serialized).unwrap();
        assert_eq!(meta_community, deserialized);

        let meta_community = MetaCommunity::Plain(Community::NoExport);
        let serialized = serde_json::to_string(&meta_community).unwrap();
        let deserialized: MetaCommunity = serde_json::from_str(&serialized).unwrap();
        assert_eq!(meta_community, deserialized);

        let meta_community = MetaCommunity::Ipv6Extended(Ipv6AddrExtCommunity {
            community_type: ExtendedCommunityType::TransitiveTwoOctetAs,
            subtype: 0,
            global_admin: "2001:db8::8a2e:370:7334".parse().unwrap(),
            local_admin: [0, 1],
        });
        let serialized = serde_json::to_string(&meta_community).unwrap();
        let deserialized: MetaCommunity = serde_json::from_str(&serialized).unwrap();
        assert_eq!(meta_community, deserialized);
    }

    #[test]
    fn test_flowspec_traffic_rate() {
        let rate = FlowSpecTrafficRate::new(64512, 1000.0);
        assert_eq!(rate.as_number, 64512);
        assert_eq!(rate.rate_bytes_per_sec, 1000.0);

        let discard = FlowSpecTrafficRate::discard(64512);
        assert_eq!(discard.rate_bytes_per_sec, 0.0);
    }

    #[test]
    fn test_flowspec_traffic_action() {
        let action = FlowSpecTrafficAction::new(64512, true, false);
        assert_eq!(action.as_number, 64512);
        assert!(action.terminal);
        assert!(!action.sample);
    }

    #[test]
    fn test_flowspec_traffic_marking() {
        let marking = FlowSpecTrafficMarking::new(64512, 46); // EF DSCP
        assert_eq!(marking.as_number, 64512);
        assert_eq!(marking.dscp, 46);

        // Test DSCP masking
        let masked = FlowSpecTrafficMarking::new(64512, 255);
        assert_eq!(masked.dscp, 63); // Should be masked to 6 bits
    }

    #[test]
    fn test_flowspec_community_display() {
        let rate = ExtendedCommunity::FlowSpecTrafficRate(FlowSpecTrafficRate::new(64512, 1000.0));
        assert_eq!(format!("{}", rate), "rate:1000 bytes/sec (AS 64512)");

        let action =
            ExtendedCommunity::FlowSpecTrafficAction(FlowSpecTrafficAction::new(64512, true, true));
        assert_eq!(format!("{}", action), "action:terminal,sample (AS 64512)");

        let marking =
            ExtendedCommunity::FlowSpecTrafficMarking(FlowSpecTrafficMarking::new(64512, 46));
        assert_eq!(format!("{}", marking), "mark:DSCP46 (AS 64512)");
    }
}
