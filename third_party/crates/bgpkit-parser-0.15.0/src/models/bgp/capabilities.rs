use crate::error::ParserError;
use crate::models::network::{Afi, Safi};
#[cfg(feature = "parser")]
use crate::parser::ReadUtils;
#[cfg(feature = "parser")]
use bytes::{BufMut, Bytes, BytesMut};
use num_enum::{FromPrimitive, IntoPrimitive};

#[allow(non_camel_case_types)]
#[derive(Debug, FromPrimitive, IntoPrimitive, PartialEq, Eq, Hash, Copy, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum BgpCapabilityType {
    MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4 = 1,
    ROUTE_REFRESH_CAPABILITY_FOR_BGP_4 = 2,
    OUTBOUND_ROUTE_FILTERING_CAPABILITY = 3,
    EXTENDED_NEXT_HOP_ENCODING = 5,
    BGP_EXTENDED_MESSAGE = 6,
    BGPSEC_CAPABILITY = 7,
    MULTIPLE_LABELS_CAPABILITY = 8,
    BGP_ROLE = 9,
    GRACEFUL_RESTART_CAPABILITY = 64,
    SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY = 65,
    SUPPORT_FOR_DYNAMIC_CAPABILITY = 67,
    MULTISESSION_BGP_CAPABILITY = 68,
    ADD_PATH_CAPABILITY = 69,
    ENHANCED_ROUTE_REFRESH_CAPABILITY = 70,
    LONG_LIVED_GRACEFUL_RESTART_CAPABILITY = 71,
    ROUTING_POLICY_DISTRIBUTION = 72,
    FQDN_CAPABILITY = 73,

    /// Catch-all type for any deprecated, unassigned, or reserved codes
    #[num_enum(catch_all)]
    Unknown(u8),
}

impl BgpCapabilityType {
    pub const fn is_deprecated(&self) -> bool {
        matches!(
            self,
            BgpCapabilityType::Unknown(4 | 66 | 128 | 129 | 130 | 131 | 184 | 185)
        )
    }

    pub const fn is_reserved(&self) -> bool {
        matches!(self, BgpCapabilityType::Unknown(0 | 255))
    }

    pub const fn is_reserved_for_experimental_use(&self) -> bool {
        matches!(self, BgpCapabilityType::Unknown(239..=254))
    }
}

/// Extended Next Hop capability entry - RFC 8950, Section 3
/// Represents a single <NLRI AFI, NLRI SAFI, NextHop AFI> triple
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExtendedNextHopEntry {
    /// Address Family Identifier for NLRI (typically AFI=1 for IPv4)
    pub nlri_afi: Afi,
    /// Subsequent Address Family Identifier for NLRI (1, 2, 4, 128, 129 per RFC 8950)
    pub nlri_safi: Safi,
    /// Address Family Identifier for Next Hop (typically AFI=2 for IPv6)  
    pub nexthop_afi: Afi,
}

/// Extended Next Hop capability - RFC 8950, Section 3
/// Contains a list of supported NLRI/NextHop AFI/SAFI combinations
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct ExtendedNextHopCapability {
    /// List of supported AFI/SAFI combinations for extended next hop encoding
    pub entries: Vec<ExtendedNextHopEntry>,
}

impl ExtendedNextHopCapability {
    /// Create a new Extended Next Hop capability with the given entries
    pub fn new(entries: Vec<ExtendedNextHopEntry>) -> Self {
        Self { entries }
    }

    /// Check if this capability supports a specific NLRI AFI/SAFI with NextHop AFI combination
    pub fn supports(&self, nlri_afi: Afi, nlri_safi: Safi, nexthop_afi: Afi) -> bool {
        self.entries.iter().any(|entry| {
            entry.nlri_afi == nlri_afi
                && entry.nlri_safi == nlri_safi
                && entry.nexthop_afi == nexthop_afi
        })
    }

    /// Get all supported NLRI AFI/SAFI combinations for a given NextHop AFI
    pub fn supported_nlri_for_nexthop(&self, nexthop_afi: Afi) -> Vec<(Afi, Safi)> {
        self.entries
            .iter()
            .filter(|entry| entry.nexthop_afi == nexthop_afi)
            .map(|entry| (entry.nlri_afi, entry.nlri_safi))
            .collect()
    }

    /// Parse Extended Next Hop capability from raw bytes - RFC 8950, Section 3
    ///
    /// Format: Series of 6-byte entries, each containing:
    /// - NLRI AFI (2 bytes)
    /// - NLRI SAFI (2 bytes)
    /// - NextHop AFI (2 bytes)
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        let mut entries = Vec::new();

        // Each entry is 6 bytes (2 + 2 + 2)
        if !data.len().is_multiple_of(6) {
            return Err(ParserError::ParseError(format!(
                "Extended Next Hop capability length {} is not divisible by 6",
                data.len()
            )));
        }

        while data.len() >= 6 {
            let nlri_afi = data.read_afi()?;
            // SAFI is encoded as 2 bytes in capability, but SAFI enum is u8
            let nlri_safi_u16 = data.read_u16()?;
            let nlri_safi = Safi::try_from(nlri_safi_u16 as u8).map_err(|_| {
                ParserError::ParseError(format!("Unknown SAFI type: {}", nlri_safi_u16))
            })?;
            let nexthop_afi = data.read_afi()?;

            entries.push(ExtendedNextHopEntry {
                nlri_afi,
                nlri_safi,
                nexthop_afi,
            });
        }

        Ok(ExtendedNextHopCapability::new(entries))
    }

    /// Encode Extended Next Hop capability to raw bytes - RFC 8950, Section 3
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(self.entries.len() * 6);

        for entry in &self.entries {
            bytes.put_u16(entry.nlri_afi as u16); // NLRI AFI (2 bytes)
            bytes.put_u16(entry.nlri_safi as u8 as u16); // NLRI SAFI (2 bytes in capability, but SAFI is u8)
            bytes.put_u16(entry.nexthop_afi as u16); // NextHop AFI (2 bytes)
        }

        bytes.freeze()
    }
}

/// Multiprotocol Extensions capability entry - RFC 2858, Section 7
/// Represents a single <AFI, SAFI> combination
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct MultiprotocolExtensionsCapability {
    /// Address Family Identifier
    pub afi: Afi,
    /// Subsequent Address Family Identifier
    pub safi: Safi,
}

impl MultiprotocolExtensionsCapability {
    /// Create a new Multiprotocol Extensions capability
    pub fn new(afi: Afi, safi: Safi) -> Self {
        Self { afi, safi }
    }

    /// Parse Multiprotocol Extensions capability from raw bytes - RFC 2858, Section 7
    ///
    /// Format: 4 bytes total
    /// - AFI (2 bytes)
    /// - Reserved (1 byte) - should be 0
    /// - SAFI (1 byte)
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        if data.len() != 4 {
            return Err(ParserError::ParseError(format!(
                "Multiprotocol Extensions capability length {} is not 4",
                data.len()
            )));
        }

        let afi = data.read_afi()?;
        let _reserved = data.read_u8()?; // Reserved field, should be 0 but ignored
        let safi_u8 = data.read_u8()?;
        let safi = Safi::try_from(safi_u8)
            .map_err(|_| ParserError::ParseError(format!("Unknown SAFI type: {}", safi_u8)))?;

        Ok(MultiprotocolExtensionsCapability::new(afi, safi))
    }

    /// Encode Multiprotocol Extensions capability to raw bytes - RFC 2858, Section 7
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(4);
        bytes.put_u16(self.afi as u16); // AFI (2 bytes)
        bytes.put_u8(0); // Reserved (1 byte) - set to 0
        bytes.put_u8(self.safi as u8); // SAFI (1 byte)
        bytes.freeze()
    }
}

/// Graceful Restart capability - RFC 4724
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct GracefulRestartCapability {
    /// Restart state flag - indicates BGP speaker has restarted
    pub restart_state: bool,
    /// Restart time in seconds
    pub restart_time: u16,
    /// List of address families that support Graceful Restart
    pub address_families: Vec<GracefulRestartAddressFamily>,
}

/// Address family entry for Graceful Restart capability - RFC 4724
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct GracefulRestartAddressFamily {
    /// Address Family Identifier
    pub afi: Afi,
    /// Subsequent Address Family Identifier
    pub safi: Safi,
    /// Forwarding state preserved flag
    pub forwarding_state: bool,
}

impl GracefulRestartCapability {
    /// Create a new Graceful Restart capability
    pub fn new(
        restart_state: bool,
        restart_time: u16,
        address_families: Vec<GracefulRestartAddressFamily>,
    ) -> Self {
        Self {
            restart_state,
            restart_time,
            address_families,
        }
    }

    /// Parse Graceful Restart capability from raw bytes - RFC 4724
    ///
    /// Format:
    /// - Restart Flags (4 bits) + Restart Time (12 bits) = 2 bytes total
    /// - Followed by 0 or more address family entries (4 bytes each)
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        if data.len() < 2 {
            return Err(ParserError::ParseError(format!(
                "Graceful Restart capability length {} is less than minimum 2 bytes",
                data.len()
            )));
        }

        // Parse restart flags and time (16 bits total)
        let restart_flags_and_time = data.read_u16()?;
        let restart_state = (restart_flags_and_time & 0x8000) != 0; // Most significant bit
        let restart_time = restart_flags_and_time & 0x0FFF; // Lower 12 bits

        let mut address_families = Vec::new();

        // Parse address family entries (4 bytes each)
        if !data.len().is_multiple_of(4) {
            return Err(ParserError::ParseError(format!(
                "Graceful Restart capability remaining length {} is not divisible by 4",
                data.len()
            )));
        }

        while data.len() >= 4 {
            let afi = data.read_afi()?;
            let safi_u8 = data.read_u8()?;
            let safi = Safi::try_from(safi_u8)
                .map_err(|_| ParserError::ParseError(format!("Unknown SAFI type: {}", safi_u8)))?;
            let flags = data.read_u8()?;
            let forwarding_state = (flags & 0x80) != 0; // Most significant bit

            address_families.push(GracefulRestartAddressFamily {
                afi,
                safi,
                forwarding_state,
            });
        }

        Ok(GracefulRestartCapability::new(
            restart_state,
            restart_time,
            address_families,
        ))
    }

    /// Encode Graceful Restart capability to raw bytes - RFC 4724
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(2 + self.address_families.len() * 4);

        // Encode restart flags and time
        let restart_flags_and_time = if self.restart_state {
            0x8000 | (self.restart_time & 0x0FFF)
        } else {
            self.restart_time & 0x0FFF
        };
        bytes.put_u16(restart_flags_and_time);

        // Encode address family entries
        for af in &self.address_families {
            bytes.put_u16(af.afi as u16); // AFI (2 bytes)
            bytes.put_u8(af.safi as u8); // SAFI (1 byte)
            let flags = if af.forwarding_state { 0x80 } else { 0x00 };
            bytes.put_u8(flags); // Flags (1 byte)
        }

        bytes.freeze()
    }
}

/// ADD-PATH capability - RFC 7911
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct AddPathCapability {
    /// List of address families and their send/receive modes
    pub address_families: Vec<AddPathAddressFamily>,
}

/// Address family entry for ADD-PATH capability - RFC 7911
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct AddPathAddressFamily {
    /// Address Family Identifier
    pub afi: Afi,
    /// Subsequent Address Family Identifier
    pub safi: Safi,
    /// Send/Receive mode
    pub send_receive: AddPathSendReceive,
}

/// Send/Receive mode for ADD-PATH capability - RFC 7911
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum AddPathSendReceive {
    /// Can receive multiple paths (value 1)
    Receive = 1,
    /// Can send multiple paths (value 2)
    Send = 2,
    /// Can both send and receive multiple paths (value 3)
    SendReceive = 3,
}

impl TryFrom<u8> for AddPathSendReceive {
    type Error = ParserError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            1 => Ok(AddPathSendReceive::Receive),
            2 => Ok(AddPathSendReceive::Send),
            3 => Ok(AddPathSendReceive::SendReceive),
            _ => Err(ParserError::ParseError(format!(
                "Invalid ADD-PATH Send/Receive value: {}",
                value
            ))),
        }
    }
}

impl AddPathCapability {
    /// Create a new ADD-PATH capability
    pub fn new(address_families: Vec<AddPathAddressFamily>) -> Self {
        Self { address_families }
    }

    /// Parse ADD-PATH capability from raw bytes - RFC 7911
    ///
    /// Format: Series of 4-byte entries, each containing:
    /// - AFI (2 bytes)
    /// - SAFI (1 byte)
    /// - Send/Receive (1 byte)
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        let mut address_families = Vec::new();

        // Each entry is 4 bytes (2 + 1 + 1)
        if !data.len().is_multiple_of(4) {
            return Err(ParserError::ParseError(format!(
                "ADD-PATH capability length {} is not divisible by 4",
                data.len()
            )));
        }

        while data.len() >= 4 {
            let afi = data.read_afi()?;
            let safi_u8 = data.read_u8()?;
            let safi = Safi::try_from(safi_u8)
                .map_err(|_| ParserError::ParseError(format!("Unknown SAFI type: {}", safi_u8)))?;
            let send_receive_u8 = data.read_u8()?;
            let send_receive = AddPathSendReceive::try_from(send_receive_u8)?;

            address_families.push(AddPathAddressFamily {
                afi,
                safi,
                send_receive,
            });
        }

        Ok(AddPathCapability::new(address_families))
    }

    /// Encode ADD-PATH capability to raw bytes - RFC 7911
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(self.address_families.len() * 4);

        for af in &self.address_families {
            bytes.put_u16(af.afi as u16); // AFI (2 bytes)
            bytes.put_u8(af.safi as u8); // SAFI (1 byte)
            bytes.put_u8(af.send_receive as u8); // Send/Receive (1 byte)
        }

        bytes.freeze()
    }
}

/// Route Refresh capability - RFC 2918
/// This capability has no parameters, it's just a flag indicating support
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RouteRefreshCapability;

impl RouteRefreshCapability {
    /// Create a new Route Refresh capability
    pub fn new() -> Self {
        Self
    }

    /// Parse Route Refresh capability from raw bytes - RFC 2918
    /// This capability has length 0, so data should be empty
    #[cfg(feature = "parser")]
    pub fn parse(data: Bytes) -> Result<Self, ParserError> {
        if !data.is_empty() {
            return Err(ParserError::ParseError(format!(
                "Route Refresh capability should have length 0, got {}",
                data.len()
            )));
        }
        Ok(RouteRefreshCapability::new())
    }

    /// Encode Route Refresh capability to raw bytes - RFC 2918
    /// Always returns empty bytes since this capability has no parameters
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        Bytes::new()
    }
}

impl Default for RouteRefreshCapability {
    fn default() -> Self {
        Self::new()
    }
}

/// BGP Extended Message capability - RFC 8654
/// This capability has no parameters, it's just a flag indicating support for extended messages
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BgpExtendedMessageCapability;

impl BgpExtendedMessageCapability {
    /// Create a new BGP Extended Message capability
    pub fn new() -> Self {
        Self
    }

    /// Parse BGP Extended Message capability from raw bytes - RFC 8654
    /// This capability has length 0, so data should be empty
    #[cfg(feature = "parser")]
    pub fn parse(data: Bytes) -> Result<Self, ParserError> {
        if !data.is_empty() {
            return Err(ParserError::ParseError(format!(
                "BGP Extended Message capability should have length 0, got {}",
                data.len()
            )));
        }
        Ok(BgpExtendedMessageCapability::new())
    }

    /// Encode BGP Extended Message capability to raw bytes - RFC 8654
    /// Always returns empty bytes since this capability has no parameters
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        Bytes::new()
    }
}

impl Default for BgpExtendedMessageCapability {
    fn default() -> Self {
        Self::new()
    }
}

/// 4-octet AS number capability - RFC 6793
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct FourOctetAsCapability {
    /// The 4-octet AS number of the BGP speaker
    pub asn: u32,
}

impl FourOctetAsCapability {
    /// Create a new 4-octet AS capability
    pub fn new(asn: u32) -> Self {
        Self { asn }
    }

    /// Parse 4-octet AS capability from raw bytes - RFC 6793
    /// Format: 4 bytes containing the AS number
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        if data.len() != 4 {
            return Err(ParserError::ParseError(format!(
                "4-octet AS capability length {} is not 4",
                data.len()
            )));
        }

        let asn = data.read_u32()?;
        Ok(FourOctetAsCapability::new(asn))
    }

    /// Encode 4-octet AS capability to raw bytes - RFC 6793
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(4);
        bytes.put_u32(self.asn);
        bytes.freeze()
    }
}

/// BGP Role capability - RFC 9234
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct BgpRoleCapability {
    /// The BGP Role of this speaker
    pub role: BgpRole,
}

/// BGP Role values - RFC 9234, Section 4.1
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum BgpRole {
    /// Provider (value 0)
    Provider = 0,
    /// Route Server (value 1)
    RouteServer = 1,
    /// Route Server Client (value 2)
    RouteServerClient = 2,
    /// Customer (value 3)
    Customer = 3,
    /// Peer (Lateral Peer) (value 4)
    Peer = 4,
}

impl TryFrom<u8> for BgpRole {
    type Error = ParserError;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        match value {
            0 => Ok(BgpRole::Provider),
            1 => Ok(BgpRole::RouteServer),
            2 => Ok(BgpRole::RouteServerClient),
            3 => Ok(BgpRole::Customer),
            4 => Ok(BgpRole::Peer),
            _ => Err(ParserError::ParseError(format!(
                "Unknown BGP Role value: {}",
                value
            ))),
        }
    }
}

impl BgpRoleCapability {
    /// Create a new BGP Role capability
    pub fn new(role: BgpRole) -> Self {
        Self { role }
    }

    /// Parse BGP Role capability from raw bytes - RFC 9234
    /// Format: 1 byte containing the role value
    #[cfg(feature = "parser")]
    pub fn parse(mut data: Bytes) -> Result<Self, ParserError> {
        if data.len() != 1 {
            return Err(ParserError::ParseError(format!(
                "BGP Role capability length {} is not 1",
                data.len()
            )));
        }

        let role_u8 = data.read_u8()?;
        let role = BgpRole::try_from(role_u8)?;
        Ok(BgpRoleCapability::new(role))
    }

    /// Encode BGP Role capability to raw bytes - RFC 9234
    #[cfg(feature = "parser")]
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(1);
        bytes.put_u8(self.role as u8);
        bytes.freeze()
    }
}

#[cfg(all(test, feature = "parser"))]
mod tests {
    use super::*;

    #[test]
    fn test_parsing_capability() {
        // reserved
        assert!(BgpCapabilityType::from(0).is_reserved());
        assert!(BgpCapabilityType::from(255).is_reserved());

        // deprecated
        for code in [4, 66, 128, 129, 130, 131, 184, 185] {
            assert!(BgpCapabilityType::from(code).is_deprecated());
        }

        // unassigned
        let unassigned_ranges = [10..=63, 74..=127, 132..=183, 186..=238];
        for code in <[_; 4]>::into_iter(unassigned_ranges).flatten() {
            let ty = BgpCapabilityType::from(code);
            assert_eq!(ty, BgpCapabilityType::Unknown(code));
            assert!(!ty.is_deprecated() && !ty.is_reserved());
        }

        // valid capabilities
        assert_eq!(
            BgpCapabilityType::from(1),
            BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4
        );
        assert_eq!(
            BgpCapabilityType::from(2),
            BgpCapabilityType::ROUTE_REFRESH_CAPABILITY_FOR_BGP_4
        );
        assert_eq!(
            BgpCapabilityType::from(3),
            BgpCapabilityType::OUTBOUND_ROUTE_FILTERING_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(5),
            BgpCapabilityType::EXTENDED_NEXT_HOP_ENCODING
        );
        assert_eq!(
            BgpCapabilityType::from(6),
            BgpCapabilityType::BGP_EXTENDED_MESSAGE
        );
        assert_eq!(
            BgpCapabilityType::from(7),
            BgpCapabilityType::BGPSEC_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(8),
            BgpCapabilityType::MULTIPLE_LABELS_CAPABILITY
        );
        assert_eq!(BgpCapabilityType::from(9), BgpCapabilityType::BGP_ROLE);

        assert_eq!(
            BgpCapabilityType::from(64),
            BgpCapabilityType::GRACEFUL_RESTART_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(65),
            BgpCapabilityType::SUPPORT_FOR_4_OCTET_AS_NUMBER_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(67),
            BgpCapabilityType::SUPPORT_FOR_DYNAMIC_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(68),
            BgpCapabilityType::MULTISESSION_BGP_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(69),
            BgpCapabilityType::ADD_PATH_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(70),
            BgpCapabilityType::ENHANCED_ROUTE_REFRESH_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(71),
            BgpCapabilityType::LONG_LIVED_GRACEFUL_RESTART_CAPABILITY
        );
        assert_eq!(
            BgpCapabilityType::from(72),
            BgpCapabilityType::ROUTING_POLICY_DISTRIBUTION
        );
        assert_eq!(
            BgpCapabilityType::from(73),
            BgpCapabilityType::FQDN_CAPABILITY
        );
    }

    #[test]
    fn test_reserved_for_experimental() {
        let experimental_ranges = [239..=254];
        for code in <[_; 1]>::into_iter(experimental_ranges).flatten() {
            let ty = BgpCapabilityType::from(code);
            assert_eq!(ty, BgpCapabilityType::Unknown(code));
            assert!(ty.is_reserved_for_experimental_use());
        }
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde() {
        let ty = BgpCapabilityType::MULTIPROTOCOL_EXTENSIONS_FOR_BGP_4;
        let serialized = serde_json::to_string(&ty).unwrap();
        let deserialized: BgpCapabilityType = serde_json::from_str(&serialized).unwrap();
        assert_eq!(ty, deserialized);
    }

    #[test]
    fn test_extended_next_hop_capability() {
        use crate::models::network::{Afi, Safi};

        // Create capability with RFC 8950 standard combinations
        let entries = vec![
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::Unicast,
                nexthop_afi: Afi::Ipv6,
            },
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::MplsVpn,
                nexthop_afi: Afi::Ipv6,
            },
        ];

        let capability = ExtendedNextHopCapability::new(entries);

        // Test supports() method
        assert!(capability.supports(Afi::Ipv4, Safi::Unicast, Afi::Ipv6));
        assert!(capability.supports(Afi::Ipv4, Safi::MplsVpn, Afi::Ipv6));
        assert!(!capability.supports(Afi::Ipv4, Safi::Multicast, Afi::Ipv6));
        assert!(!capability.supports(Afi::Ipv6, Safi::Unicast, Afi::Ipv6));

        // Test supported_nlri_for_nexthop() method
        let supported = capability.supported_nlri_for_nexthop(Afi::Ipv6);
        assert_eq!(supported.len(), 2);
        assert!(supported.contains(&(Afi::Ipv4, Safi::Unicast)));
        assert!(supported.contains(&(Afi::Ipv4, Safi::MplsVpn)));

        let no_support = capability.supported_nlri_for_nexthop(Afi::Ipv4);
        assert!(no_support.is_empty());
    }

    #[test]
    fn test_extended_next_hop_capability_parsing() {
        use crate::models::network::{Afi, Safi};

        // Test parsing valid capability data
        // Entry 1: IPv4 Unicast (AFI=1, SAFI=1) with IPv6 NextHop (AFI=2)
        // Entry 2: IPv4 MPLS VPN (AFI=1, SAFI=128) with IPv6 NextHop (AFI=2)
        let capability_bytes = Bytes::from(vec![
            0x00, 0x01, // NLRI AFI = 1 (IPv4)
            0x00, 0x01, // NLRI SAFI = 1 (Unicast)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
            0x00, 0x01, // NLRI AFI = 1 (IPv4)
            0x00, 0x80, // NLRI SAFI = 128 (MPLS VPN)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
        ]);

        let parsed = ExtendedNextHopCapability::parse(capability_bytes).unwrap();

        assert_eq!(parsed.entries.len(), 2);

        // Check first entry
        assert_eq!(parsed.entries[0].nlri_afi, Afi::Ipv4);
        assert_eq!(parsed.entries[0].nlri_safi, Safi::Unicast);
        assert_eq!(parsed.entries[0].nexthop_afi, Afi::Ipv6);

        // Check second entry
        assert_eq!(parsed.entries[1].nlri_afi, Afi::Ipv4);
        assert_eq!(parsed.entries[1].nlri_safi, Safi::MplsVpn);
        assert_eq!(parsed.entries[1].nexthop_afi, Afi::Ipv6);

        // Test functionality
        assert!(parsed.supports(Afi::Ipv4, Safi::Unicast, Afi::Ipv6));
        assert!(parsed.supports(Afi::Ipv4, Safi::MplsVpn, Afi::Ipv6));
        assert!(!parsed.supports(Afi::Ipv4, Safi::Multicast, Afi::Ipv6));
    }

    #[test]
    fn test_extended_next_hop_capability_encoding() {
        use crate::models::network::{Afi, Safi};

        let entries = vec![
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::Unicast,
                nexthop_afi: Afi::Ipv6,
            },
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::MplsVpn,
                nexthop_afi: Afi::Ipv6,
            },
        ];

        let capability = ExtendedNextHopCapability::new(entries);
        let encoded = capability.encode();

        let expected = vec![
            0x00, 0x01, // NLRI AFI = 1 (IPv4)
            0x00, 0x01, // NLRI SAFI = 1 (Unicast)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
            0x00, 0x01, // NLRI AFI = 1 (IPv4)
            0x00, 0x80, // NLRI SAFI = 128 (MPLS VPN)
            0x00, 0x02, // NextHop AFI = 2 (IPv6)
        ];

        assert_eq!(encoded.to_vec(), expected);
    }

    #[test]
    fn test_extended_next_hop_capability_round_trip() {
        use crate::models::network::{Afi, Safi};

        let original_entries = vec![
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::Unicast,
                nexthop_afi: Afi::Ipv6,
            },
            ExtendedNextHopEntry {
                nlri_afi: Afi::Ipv4,
                nlri_safi: Safi::MulticastVpn,
                nexthop_afi: Afi::Ipv6,
            },
        ];

        let original = ExtendedNextHopCapability::new(original_entries);
        let encoded = original.encode();
        let parsed = ExtendedNextHopCapability::parse(encoded).unwrap();

        assert_eq!(original, parsed);
    }

    #[test]
    fn test_extended_next_hop_capability_invalid_length() {
        // Test with invalid length (not divisible by 6)
        let invalid_bytes = Bytes::from(vec![0x00, 0x01, 0x00, 0x01, 0x00]); // 5 bytes
        let result = ExtendedNextHopCapability::parse(invalid_bytes);
        assert!(result.is_err());

        if let Err(ParserError::ParseError(msg)) = result {
            assert!(msg.contains("not divisible by 6"));
        } else {
            panic!("Expected ParseError with divisibility message");
        }
    }

    #[test]
    fn test_extended_next_hop_capability_empty() {
        // Test with empty capability (valid - no entries)
        let empty_bytes = Bytes::from(vec![]);
        let parsed = ExtendedNextHopCapability::parse(empty_bytes).unwrap();
        assert_eq!(parsed.entries.len(), 0);

        // Test encoding empty capability
        let empty_capability = ExtendedNextHopCapability::new(vec![]);
        let encoded = empty_capability.encode();
        assert_eq!(encoded.len(), 0);
    }

    #[test]
    fn test_multiprotocol_extensions_capability() {
        use crate::models::network::{Afi, Safi};

        // Test IPv4 Unicast capability
        let capability = MultiprotocolExtensionsCapability::new(Afi::Ipv4, Safi::Unicast);

        // Test encoding
        let encoded = capability.encode();
        assert_eq!(encoded.len(), 4);
        assert_eq!(encoded[0], 0x00); // AFI high byte
        assert_eq!(encoded[1], 0x01); // AFI low byte (IPv4)
        assert_eq!(encoded[2], 0x00); // Reserved
        assert_eq!(encoded[3], 0x01); // SAFI (Unicast)

        // Test parsing
        let parsed = MultiprotocolExtensionsCapability::parse(encoded).unwrap();
        assert_eq!(parsed.afi, Afi::Ipv4);
        assert_eq!(parsed.safi, Safi::Unicast);
        assert_eq!(parsed, capability);
    }

    #[test]
    fn test_multiprotocol_extensions_capability_ipv6() {
        use crate::models::network::{Afi, Safi};

        // Test IPv6 Multicast capability
        let capability = MultiprotocolExtensionsCapability::new(Afi::Ipv6, Safi::Multicast);

        let encoded = capability.encode();
        let parsed = MultiprotocolExtensionsCapability::parse(encoded).unwrap();
        assert_eq!(parsed.afi, Afi::Ipv6);
        assert_eq!(parsed.safi, Safi::Multicast);
    }

    #[test]
    fn test_multiprotocol_extensions_capability_invalid_length() {
        // Test with invalid length
        let invalid_bytes = Bytes::from(vec![0x00, 0x01, 0x00]); // 3 bytes instead of 4
        let result = MultiprotocolExtensionsCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_graceful_restart_capability() {
        use crate::models::network::{Afi, Safi};

        // Create capability with restart state and multiple address families
        let address_families = vec![
            GracefulRestartAddressFamily {
                afi: Afi::Ipv4,
                safi: Safi::Unicast,
                forwarding_state: true,
            },
            GracefulRestartAddressFamily {
                afi: Afi::Ipv6,
                safi: Safi::Unicast,
                forwarding_state: false,
            },
        ];

        let capability = GracefulRestartCapability::new(true, 180, address_families);

        // Test encoding
        let encoded = capability.encode();
        assert_eq!(encoded.len(), 2 + 2 * 4); // 2 header bytes + 2 AF entries * 4 bytes each

        // Test parsing
        let parsed = GracefulRestartCapability::parse(encoded).unwrap();
        assert!(parsed.restart_state);
        assert_eq!(parsed.restart_time, 180);
        assert_eq!(parsed.address_families.len(), 2);

        // Check first AF
        assert_eq!(parsed.address_families[0].afi, Afi::Ipv4);
        assert_eq!(parsed.address_families[0].safi, Safi::Unicast);
        assert!(parsed.address_families[0].forwarding_state);

        // Check second AF
        assert_eq!(parsed.address_families[1].afi, Afi::Ipv6);
        assert_eq!(parsed.address_families[1].safi, Safi::Unicast);
        assert!(!parsed.address_families[1].forwarding_state);
    }

    #[test]
    fn test_graceful_restart_capability_no_restart_state() {
        // Test without restart state flag
        let capability = GracefulRestartCapability::new(false, 300, vec![]);

        let encoded = capability.encode();
        let parsed = GracefulRestartCapability::parse(encoded).unwrap();
        assert!(!parsed.restart_state);
        assert_eq!(parsed.restart_time, 300);
        assert_eq!(parsed.address_families.len(), 0);
    }

    #[test]
    fn test_graceful_restart_capability_invalid_length() {
        // Test with length that's not divisible by 4 after header
        let invalid_bytes = Bytes::from(vec![0x80, 0xB4, 0x00, 0x01, 0x01]); // 5 bytes total, 3 after header
        let result = GracefulRestartCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_add_path_capability() {
        use crate::models::network::{Afi, Safi};

        // Create capability with multiple address families
        let address_families = vec![
            AddPathAddressFamily {
                afi: Afi::Ipv4,
                safi: Safi::Unicast,
                send_receive: AddPathSendReceive::SendReceive,
            },
            AddPathAddressFamily {
                afi: Afi::Ipv6,
                safi: Safi::Unicast,
                send_receive: AddPathSendReceive::Receive,
            },
        ];

        let capability = AddPathCapability::new(address_families);

        // Test encoding
        let encoded = capability.encode();
        assert_eq!(encoded.len(), 2 * 4); // 2 AF entries * 4 bytes each

        // Test parsing
        let parsed = AddPathCapability::parse(encoded).unwrap();
        assert_eq!(parsed.address_families.len(), 2);

        // Check first AF
        assert_eq!(parsed.address_families[0].afi, Afi::Ipv4);
        assert_eq!(parsed.address_families[0].safi, Safi::Unicast);
        assert_eq!(
            parsed.address_families[0].send_receive,
            AddPathSendReceive::SendReceive
        );

        // Check second AF
        assert_eq!(parsed.address_families[1].afi, Afi::Ipv6);
        assert_eq!(parsed.address_families[1].safi, Safi::Unicast);
        assert_eq!(
            parsed.address_families[1].send_receive,
            AddPathSendReceive::Receive
        );
    }

    #[test]
    fn test_add_path_send_receive_values() {
        use AddPathSendReceive::*;

        assert_eq!(Receive as u8, 1);
        assert_eq!(Send as u8, 2);
        assert_eq!(SendReceive as u8, 3);

        assert_eq!(AddPathSendReceive::try_from(1).unwrap(), Receive);
        assert_eq!(AddPathSendReceive::try_from(2).unwrap(), Send);
        assert_eq!(AddPathSendReceive::try_from(3).unwrap(), SendReceive);

        // Invalid value
        assert!(AddPathSendReceive::try_from(4).is_err());
    }

    #[test]
    fn test_add_path_capability_invalid_length() {
        // Test with length that's not divisible by 4
        let invalid_bytes = Bytes::from(vec![0x00, 0x01, 0x01]); // 3 bytes
        let result = AddPathCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_add_path_capability_empty() {
        // Test with empty capability (valid - no entries)
        let empty_bytes = Bytes::from(vec![]);
        let parsed = AddPathCapability::parse(empty_bytes).unwrap();
        assert_eq!(parsed.address_families.len(), 0);

        // Test encoding empty capability
        let empty_capability = AddPathCapability::new(vec![]);
        let encoded = empty_capability.encode();
        assert_eq!(encoded.len(), 0);
    }

    #[test]
    fn test_route_refresh_capability() {
        // Test creation
        let capability = RouteRefreshCapability::new();

        // Test encoding (should be empty)
        let encoded = capability.encode();
        assert_eq!(encoded.len(), 0);

        // Test parsing (should accept empty data)
        let parsed = RouteRefreshCapability::parse(encoded).unwrap();
        assert_eq!(parsed, capability);
    }

    #[test]
    fn test_route_refresh_capability_invalid_length() {
        // Test with non-empty data (should fail)
        let invalid_bytes = Bytes::from(vec![0x01]);
        let result = RouteRefreshCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_four_octet_as_capability() {
        // Test various AS numbers
        let test_cases = [0, 65535, 65536, 4294967295];

        for asn in test_cases {
            let capability = FourOctetAsCapability::new(asn);

            // Test encoding
            let encoded = capability.encode();
            assert_eq!(encoded.len(), 4);

            // Test parsing
            let parsed = FourOctetAsCapability::parse(encoded).unwrap();
            assert_eq!(parsed.asn, asn);
            assert_eq!(parsed, capability);
        }
    }

    #[test]
    fn test_four_octet_as_capability_invalid_length() {
        // Test with wrong length
        let invalid_bytes = Bytes::from(vec![0x00, 0x01, 0x00]); // 3 bytes instead of 4
        let result = FourOctetAsCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_bgp_role_capability() {
        use BgpRole::*;

        // Test all valid role values
        let test_cases = [
            (Provider, 0),
            (RouteServer, 1),
            (RouteServerClient, 2),
            (Customer, 3),
            (Peer, 4),
        ];

        for (role, expected_value) in test_cases {
            let capability = BgpRoleCapability::new(role);

            // Test encoding
            let encoded = capability.encode();
            assert_eq!(encoded.len(), 1);
            assert_eq!(encoded[0], expected_value);

            // Test parsing
            let parsed = BgpRoleCapability::parse(encoded).unwrap();
            assert_eq!(parsed.role, role);
            assert_eq!(parsed, capability);
        }
    }

    #[test]
    fn test_bgp_role_values() {
        use BgpRole::*;

        // Test enum values
        assert_eq!(Provider as u8, 0);
        assert_eq!(RouteServer as u8, 1);
        assert_eq!(RouteServerClient as u8, 2);
        assert_eq!(Customer as u8, 3);
        assert_eq!(Peer as u8, 4);

        // Test TryFrom conversion
        assert_eq!(BgpRole::try_from(0).unwrap(), Provider);
        assert_eq!(BgpRole::try_from(1).unwrap(), RouteServer);
        assert_eq!(BgpRole::try_from(2).unwrap(), RouteServerClient);
        assert_eq!(BgpRole::try_from(3).unwrap(), Customer);
        assert_eq!(BgpRole::try_from(4).unwrap(), Peer);

        // Test invalid value
        assert!(BgpRole::try_from(5).is_err());
        assert!(BgpRole::try_from(255).is_err());
    }

    #[test]
    fn test_bgp_role_capability_invalid_length() {
        // Test with wrong length
        let invalid_bytes = Bytes::from(vec![0x00, 0x01]); // 2 bytes instead of 1
        let result = BgpRoleCapability::parse(invalid_bytes);
        assert!(result.is_err());

        // Test with empty data
        let empty_bytes = Bytes::from(vec![]);
        let result = BgpRoleCapability::parse(empty_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_bgp_role_capability_invalid_value() {
        // Test with invalid role value
        let invalid_bytes = Bytes::from(vec![5]); // 5 is not a valid role
        let result = BgpRoleCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }

    #[test]
    fn test_bgp_extended_message_capability() {
        // Test creation
        let capability = BgpExtendedMessageCapability::new();

        // Test encoding (should be empty)
        let encoded = capability.encode();
        assert_eq!(encoded.len(), 0);

        // Test parsing (should accept empty data)
        let parsed = BgpExtendedMessageCapability::parse(encoded).unwrap();
        assert_eq!(parsed, capability);
    }

    #[test]
    fn test_bgp_extended_message_capability_invalid_length() {
        // Test with non-empty data (should fail)
        let invalid_bytes = Bytes::from(vec![0x01]);
        let result = BgpExtendedMessageCapability::parse(invalid_bytes);
        assert!(result.is_err());
    }
}
