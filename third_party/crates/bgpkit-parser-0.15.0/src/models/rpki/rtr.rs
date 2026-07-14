//! RPKI-to-Router (RTR) Protocol Data Structures
//!
//! This module defines the data structures for the RTR protocol as specified in:
//! - RTR v0: [RFC 6810](https://www.rfc-editor.org/rfc/rfc6810.txt)
//! - RTR v1: [RFC 8210](https://www.rfc-editor.org/rfc/rfc8210.txt)
//!
//! The RTR protocol is used to deliver validated RPKI data from a cache server
//! to a router. This module provides PDU definitions that can be used by
//! downstream clients to implement RTR protocol communication.
//!
//! # Example
//!
//! ```rust
//! use bgpkit_parser::models::rpki::rtr::*;
//!
//! // Create a reset query to request the full database
//! let query = RtrResetQuery {
//!     version: RtrProtocolVersion::V1,
//! };
//!
//! // Check if a prefix PDU is an announcement or withdrawal
//! let prefix = RtrIPv4Prefix {
//!     version: RtrProtocolVersion::V1,
//!     flags: 1, // announcement
//!     prefix_length: 24,
//!     max_length: 24,
//!     prefix: std::net::Ipv4Addr::new(192, 0, 2, 0),
//!     asn: 65001.into(),
//! };
//! assert!(prefix.is_announcement());
//! ```

use crate::models::Asn;
use std::net::{Ipv4Addr, Ipv6Addr};

// =============================================================================
// Core Enums
// =============================================================================

/// RTR Protocol Version
///
/// The RTR protocol has two versions:
/// - V0 (RFC 6810): Original protocol specification
/// - V1 (RFC 8210): Adds Router Key PDU and timing parameters in End of Data
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum RtrProtocolVersion {
    /// RTR Protocol Version 0 (RFC 6810)
    V0 = 0,
    /// RTR Protocol Version 1 (RFC 8210)
    #[default]
    V1 = 1,
}

impl RtrProtocolVersion {
    /// Create from a raw byte value
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(RtrProtocolVersion::V0),
            1 => Some(RtrProtocolVersion::V1),
            _ => None,
        }
    }

    /// Convert to raw byte value
    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

impl From<RtrProtocolVersion> for u8 {
    fn from(v: RtrProtocolVersion) -> Self {
        v as u8
    }
}

impl TryFrom<u8> for RtrProtocolVersion {
    type Error = u8;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        RtrProtocolVersion::from_u8(value).ok_or(value)
    }
}

/// RTR PDU Type
///
/// Identifies the type of RTR Protocol Data Unit.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum RtrPduType {
    /// Serial Notify - Server notifies client of new data available
    SerialNotify = 0,
    /// Serial Query - Client requests incremental update
    SerialQuery = 1,
    /// Reset Query - Client requests full database
    ResetQuery = 2,
    /// Cache Response - Server begins sending data
    CacheResponse = 3,
    /// IPv4 Prefix - ROA for IPv4
    IPv4Prefix = 4,
    /// IPv6 Prefix - ROA for IPv6
    IPv6Prefix = 6,
    /// End of Data - Server finished sending data
    EndOfData = 7,
    /// Cache Reset - Server cannot provide incremental update
    CacheReset = 8,
    /// Router Key - BGPsec router key (v1 only)
    RouterKey = 9,
    /// Error Report - Error notification
    ErrorReport = 10,
}

impl RtrPduType {
    /// Create from a raw byte value
    pub fn from_u8(value: u8) -> Option<Self> {
        match value {
            0 => Some(RtrPduType::SerialNotify),
            1 => Some(RtrPduType::SerialQuery),
            2 => Some(RtrPduType::ResetQuery),
            3 => Some(RtrPduType::CacheResponse),
            4 => Some(RtrPduType::IPv4Prefix),
            6 => Some(RtrPduType::IPv6Prefix),
            7 => Some(RtrPduType::EndOfData),
            8 => Some(RtrPduType::CacheReset),
            9 => Some(RtrPduType::RouterKey),
            10 => Some(RtrPduType::ErrorReport),
            _ => None,
        }
    }

    /// Convert to raw byte value
    pub fn to_u8(self) -> u8 {
        self as u8
    }
}

impl From<RtrPduType> for u8 {
    fn from(v: RtrPduType) -> Self {
        v as u8
    }
}

impl TryFrom<u8> for RtrPduType {
    type Error = u8;

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        RtrPduType::from_u8(value).ok_or(value)
    }
}

/// RTR Error Code
///
/// Error codes used in Error Report PDUs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum RtrErrorCode {
    /// Corrupt Data - PDU could not be parsed
    CorruptData = 0,
    /// Internal Error - Cache experienced an internal error
    InternalError = 1,
    /// No Data Available - Cache has no data yet
    NoDataAvailable = 2,
    /// Invalid Request - Request was invalid
    InvalidRequest = 3,
    /// Unsupported Protocol Version - Protocol version not supported
    UnsupportedProtocolVersion = 4,
    /// Unsupported PDU Type - PDU type not supported
    UnsupportedPduType = 5,
    /// Withdrawal of Unknown Record - Tried to withdraw non-existent record
    WithdrawalOfUnknownRecord = 6,
    /// Duplicate Announcement Received - Same record announced twice
    DuplicateAnnouncementReceived = 7,
    /// Unexpected Protocol Version - Version mismatch mid-session (v1 only)
    UnexpectedProtocolVersion = 8,
}

impl RtrErrorCode {
    /// Create from a raw u16 value
    pub fn from_u16(value: u16) -> Option<Self> {
        match value {
            0 => Some(RtrErrorCode::CorruptData),
            1 => Some(RtrErrorCode::InternalError),
            2 => Some(RtrErrorCode::NoDataAvailable),
            3 => Some(RtrErrorCode::InvalidRequest),
            4 => Some(RtrErrorCode::UnsupportedProtocolVersion),
            5 => Some(RtrErrorCode::UnsupportedPduType),
            6 => Some(RtrErrorCode::WithdrawalOfUnknownRecord),
            7 => Some(RtrErrorCode::DuplicateAnnouncementReceived),
            8 => Some(RtrErrorCode::UnexpectedProtocolVersion),
            _ => None,
        }
    }

    /// Convert to raw u16 value
    pub fn to_u16(self) -> u16 {
        self as u16
    }
}

impl From<RtrErrorCode> for u16 {
    fn from(v: RtrErrorCode) -> Self {
        v as u16
    }
}

impl TryFrom<u16> for RtrErrorCode {
    type Error = u16;

    fn try_from(value: u16) -> Result<Self, Self::Error> {
        RtrErrorCode::from_u16(value).ok_or(value)
    }
}

// =============================================================================
// PDU Structs
// =============================================================================

/// Serial Notify PDU (Type 0)
///
/// Sent by server to notify client that new data is available.
/// This is a hint that the client should send a Serial Query.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrSerialNotify {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Session identifier
    pub session_id: u16,
    /// Current serial number
    pub serial_number: u32,
}

/// Serial Query PDU (Type 1)
///
/// Sent by client to request incremental update from a known serial number.
///
/// Direction: Client → Server
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrSerialQuery {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Session identifier from previous session
    pub session_id: u16,
    /// Last known serial number
    pub serial_number: u32,
}

impl RtrSerialQuery {
    /// Create a new Serial Query PDU
    pub fn new(version: RtrProtocolVersion, session_id: u16, serial_number: u32) -> Self {
        Self {
            version,
            session_id,
            serial_number,
        }
    }
}

/// Reset Query PDU (Type 2)
///
/// Sent by client to request the full database from the server.
///
/// Direction: Client → Server
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrResetQuery {
    /// Protocol version
    pub version: RtrProtocolVersion,
}

impl RtrResetQuery {
    /// Create a new Reset Query PDU with the specified version
    pub fn new(version: RtrProtocolVersion) -> Self {
        Self { version }
    }

    /// Create a new Reset Query PDU with version 1
    pub fn new_v1() -> Self {
        Self::new(RtrProtocolVersion::V1)
    }

    /// Create a new Reset Query PDU with version 0
    pub fn new_v0() -> Self {
        Self::new(RtrProtocolVersion::V0)
    }
}

impl Default for RtrResetQuery {
    fn default() -> Self {
        Self::new_v1()
    }
}

/// Cache Response PDU (Type 3)
///
/// Sent by server to indicate the start of a data transfer.
/// Followed by zero or more IPv4/IPv6 Prefix and Router Key PDUs,
/// and terminated by an End of Data PDU.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrCacheResponse {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Session identifier
    pub session_id: u16,
}

/// IPv4 Prefix PDU (Type 4)
///
/// Contains a single ROA for an IPv4 prefix.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrIPv4Prefix {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Flags (bit 0: 1=announcement, 0=withdrawal)
    pub flags: u8,
    /// Prefix length in bits
    pub prefix_length: u8,
    /// Maximum prefix length for this ROA
    pub max_length: u8,
    /// IPv4 prefix
    pub prefix: Ipv4Addr,
    /// Origin AS number
    pub asn: Asn,
}

impl RtrIPv4Prefix {
    /// Check if this is an announcement (not a withdrawal)
    #[inline]
    pub fn is_announcement(&self) -> bool {
        self.flags & 0x01 != 0
    }

    /// Check if this is a withdrawal
    #[inline]
    pub fn is_withdrawal(&self) -> bool {
        !self.is_announcement()
    }
}

/// IPv6 Prefix PDU (Type 6)
///
/// Contains a single ROA for an IPv6 prefix.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrIPv6Prefix {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Flags (bit 0: 1=announcement, 0=withdrawal)
    pub flags: u8,
    /// Prefix length in bits
    pub prefix_length: u8,
    /// Maximum prefix length for this ROA
    pub max_length: u8,
    /// IPv6 prefix
    pub prefix: Ipv6Addr,
    /// Origin AS number
    pub asn: Asn,
}

impl RtrIPv6Prefix {
    /// Check if this is an announcement (not a withdrawal)
    #[inline]
    pub fn is_announcement(&self) -> bool {
        self.flags & 0x01 != 0
    }

    /// Check if this is a withdrawal
    #[inline]
    pub fn is_withdrawal(&self) -> bool {
        !self.is_announcement()
    }
}

/// End of Data PDU (Type 7)
///
/// Sent by server to indicate the end of a data transfer.
///
/// Direction: Server → Client
///
/// Note: In v1, this PDU includes timing parameters. In v0, these are absent.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrEndOfData {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Session identifier
    pub session_id: u16,
    /// Current serial number
    pub serial_number: u32,
    /// Refresh interval in seconds (v1 only)
    pub refresh_interval: Option<u32>,
    /// Retry interval in seconds (v1 only)
    pub retry_interval: Option<u32>,
    /// Expire interval in seconds (v1 only)
    pub expire_interval: Option<u32>,
}

impl RtrEndOfData {
    /// Default refresh interval (1 hour) as recommended by RFC 8210
    pub const DEFAULT_REFRESH: u32 = 3600;
    /// Default retry interval (10 minutes) as recommended by RFC 8210
    pub const DEFAULT_RETRY: u32 = 600;
    /// Default expire interval (2 hours) as recommended by RFC 8210
    pub const DEFAULT_EXPIRE: u32 = 7200;

    /// Get the refresh interval, using the default if not specified
    pub fn refresh_interval_or_default(&self) -> u32 {
        self.refresh_interval.unwrap_or(Self::DEFAULT_REFRESH)
    }

    /// Get the retry interval, using the default if not specified
    pub fn retry_interval_or_default(&self) -> u32 {
        self.retry_interval.unwrap_or(Self::DEFAULT_RETRY)
    }

    /// Get the expire interval, using the default if not specified
    pub fn expire_interval_or_default(&self) -> u32 {
        self.expire_interval.unwrap_or(Self::DEFAULT_EXPIRE)
    }
}

/// Cache Reset PDU (Type 8)
///
/// Sent by server in response to a Serial Query when the server
/// cannot provide an incremental update (e.g., serial is too old).
/// The client should send a Reset Query.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrCacheReset {
    /// Protocol version
    pub version: RtrProtocolVersion,
}

/// Router Key PDU (Type 9, v1 only)
///
/// Contains a BGPsec router key.
///
/// Direction: Server → Client
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrRouterKey {
    /// Protocol version (always V1)
    pub version: RtrProtocolVersion,
    /// Flags (bit 0: 1=announcement, 0=withdrawal)
    pub flags: u8,
    /// Subject Key Identifier (SKI) - 20 bytes
    pub subject_key_identifier: [u8; 20],
    /// AS number
    pub asn: Asn,
    /// Subject Public Key Info (SPKI) - variable length
    pub subject_public_key_info: Vec<u8>,
}

impl RtrRouterKey {
    /// Check if this is an announcement (not a withdrawal)
    #[inline]
    pub fn is_announcement(&self) -> bool {
        self.flags & 0x01 != 0
    }

    /// Check if this is a withdrawal
    #[inline]
    pub fn is_withdrawal(&self) -> bool {
        !self.is_announcement()
    }
}

/// Error Report PDU (Type 10)
///
/// Sent by either client or server to report an error.
///
/// Direction: Bidirectional (Client ↔ Server)
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RtrErrorReport {
    /// Protocol version
    pub version: RtrProtocolVersion,
    /// Error code
    pub error_code: RtrErrorCode,
    /// The erroneous PDU that caused the error (may be empty)
    pub erroneous_pdu: Vec<u8>,
    /// Human-readable error text (UTF-8)
    pub error_text: String,
}

impl RtrErrorReport {
    /// Create a new Error Report PDU
    pub fn new(
        version: RtrProtocolVersion,
        error_code: RtrErrorCode,
        erroneous_pdu: Vec<u8>,
        error_text: String,
    ) -> Self {
        Self {
            version,
            error_code,
            erroneous_pdu,
            error_text,
        }
    }

    /// Create an error report for unsupported protocol version
    pub fn unsupported_version(version: RtrProtocolVersion, erroneous_pdu: Vec<u8>) -> Self {
        Self::new(
            version,
            RtrErrorCode::UnsupportedProtocolVersion,
            erroneous_pdu,
            "Unsupported protocol version".to_string(),
        )
    }

    /// Create an error report for unsupported PDU type
    pub fn unsupported_pdu_type(version: RtrProtocolVersion, erroneous_pdu: Vec<u8>) -> Self {
        Self::new(
            version,
            RtrErrorCode::UnsupportedPduType,
            erroneous_pdu,
            "Unsupported PDU type".to_string(),
        )
    }

    /// Create an error report for corrupt data
    pub fn corrupt_data(
        version: RtrProtocolVersion,
        erroneous_pdu: Vec<u8>,
        message: &str,
    ) -> Self {
        Self::new(
            version,
            RtrErrorCode::CorruptData,
            erroneous_pdu,
            message.to_string(),
        )
    }
}

// =============================================================================
// Unified PDU Enum
// =============================================================================

/// Unified RTR PDU Enum
///
/// This enum represents any RTR Protocol Data Unit and is useful for
/// generic PDU handling when reading from a stream.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum RtrPdu {
    /// Serial Notify (Type 0)
    SerialNotify(RtrSerialNotify),
    /// Serial Query (Type 1)
    SerialQuery(RtrSerialQuery),
    /// Reset Query (Type 2)
    ResetQuery(RtrResetQuery),
    /// Cache Response (Type 3)
    CacheResponse(RtrCacheResponse),
    /// IPv4 Prefix (Type 4)
    IPv4Prefix(RtrIPv4Prefix),
    /// IPv6 Prefix (Type 6)
    IPv6Prefix(RtrIPv6Prefix),
    /// End of Data (Type 7)
    EndOfData(RtrEndOfData),
    /// Cache Reset (Type 8)
    CacheReset(RtrCacheReset),
    /// Router Key (Type 9, v1 only)
    RouterKey(RtrRouterKey),
    /// Error Report (Type 10)
    ErrorReport(RtrErrorReport),
}

impl RtrPdu {
    /// Get the PDU type
    pub fn pdu_type(&self) -> RtrPduType {
        match self {
            RtrPdu::SerialNotify(_) => RtrPduType::SerialNotify,
            RtrPdu::SerialQuery(_) => RtrPduType::SerialQuery,
            RtrPdu::ResetQuery(_) => RtrPduType::ResetQuery,
            RtrPdu::CacheResponse(_) => RtrPduType::CacheResponse,
            RtrPdu::IPv4Prefix(_) => RtrPduType::IPv4Prefix,
            RtrPdu::IPv6Prefix(_) => RtrPduType::IPv6Prefix,
            RtrPdu::EndOfData(_) => RtrPduType::EndOfData,
            RtrPdu::CacheReset(_) => RtrPduType::CacheReset,
            RtrPdu::RouterKey(_) => RtrPduType::RouterKey,
            RtrPdu::ErrorReport(_) => RtrPduType::ErrorReport,
        }
    }

    /// Get the protocol version
    pub fn version(&self) -> RtrProtocolVersion {
        match self {
            RtrPdu::SerialNotify(p) => p.version,
            RtrPdu::SerialQuery(p) => p.version,
            RtrPdu::ResetQuery(p) => p.version,
            RtrPdu::CacheResponse(p) => p.version,
            RtrPdu::IPv4Prefix(p) => p.version,
            RtrPdu::IPv6Prefix(p) => p.version,
            RtrPdu::EndOfData(p) => p.version,
            RtrPdu::CacheReset(p) => p.version,
            RtrPdu::RouterKey(p) => p.version,
            RtrPdu::ErrorReport(p) => p.version,
        }
    }
}

impl From<RtrSerialNotify> for RtrPdu {
    fn from(pdu: RtrSerialNotify) -> Self {
        RtrPdu::SerialNotify(pdu)
    }
}

impl From<RtrSerialQuery> for RtrPdu {
    fn from(pdu: RtrSerialQuery) -> Self {
        RtrPdu::SerialQuery(pdu)
    }
}

impl From<RtrResetQuery> for RtrPdu {
    fn from(pdu: RtrResetQuery) -> Self {
        RtrPdu::ResetQuery(pdu)
    }
}

impl From<RtrCacheResponse> for RtrPdu {
    fn from(pdu: RtrCacheResponse) -> Self {
        RtrPdu::CacheResponse(pdu)
    }
}

impl From<RtrIPv4Prefix> for RtrPdu {
    fn from(pdu: RtrIPv4Prefix) -> Self {
        RtrPdu::IPv4Prefix(pdu)
    }
}

impl From<RtrIPv6Prefix> for RtrPdu {
    fn from(pdu: RtrIPv6Prefix) -> Self {
        RtrPdu::IPv6Prefix(pdu)
    }
}

impl From<RtrEndOfData> for RtrPdu {
    fn from(pdu: RtrEndOfData) -> Self {
        RtrPdu::EndOfData(pdu)
    }
}

impl From<RtrCacheReset> for RtrPdu {
    fn from(pdu: RtrCacheReset) -> Self {
        RtrPdu::CacheReset(pdu)
    }
}

impl From<RtrRouterKey> for RtrPdu {
    fn from(pdu: RtrRouterKey) -> Self {
        RtrPdu::RouterKey(pdu)
    }
}

impl From<RtrErrorReport> for RtrPdu {
    fn from(pdu: RtrErrorReport) -> Self {
        RtrPdu::ErrorReport(pdu)
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_protocol_version_conversion() {
        assert_eq!(RtrProtocolVersion::from_u8(0), Some(RtrProtocolVersion::V0));
        assert_eq!(RtrProtocolVersion::from_u8(1), Some(RtrProtocolVersion::V1));
        assert_eq!(RtrProtocolVersion::from_u8(2), None);

        assert_eq!(RtrProtocolVersion::V0.to_u8(), 0);
        assert_eq!(RtrProtocolVersion::V1.to_u8(), 1);
    }

    #[test]
    fn test_pdu_type_conversion() {
        assert_eq!(RtrPduType::from_u8(0), Some(RtrPduType::SerialNotify));
        assert_eq!(RtrPduType::from_u8(1), Some(RtrPduType::SerialQuery));
        assert_eq!(RtrPduType::from_u8(4), Some(RtrPduType::IPv4Prefix));
        assert_eq!(RtrPduType::from_u8(5), None); // No type 5
        assert_eq!(RtrPduType::from_u8(6), Some(RtrPduType::IPv6Prefix));
        assert_eq!(RtrPduType::from_u8(9), Some(RtrPduType::RouterKey));

        assert_eq!(RtrPduType::SerialNotify.to_u8(), 0);
        assert_eq!(RtrPduType::IPv6Prefix.to_u8(), 6);
    }

    #[test]
    fn test_error_code_conversion() {
        assert_eq!(RtrErrorCode::from_u16(0), Some(RtrErrorCode::CorruptData));
        assert_eq!(
            RtrErrorCode::from_u16(4),
            Some(RtrErrorCode::UnsupportedProtocolVersion)
        );
        assert_eq!(
            RtrErrorCode::from_u16(8),
            Some(RtrErrorCode::UnexpectedProtocolVersion)
        );
        assert_eq!(RtrErrorCode::from_u16(9), None);

        assert_eq!(RtrErrorCode::CorruptData.to_u16(), 0);
        assert_eq!(RtrErrorCode::UnsupportedProtocolVersion.to_u16(), 4);
    }

    #[test]
    fn test_ipv4_prefix_flags() {
        let announcement = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(192, 0, 2, 0),
            asn: 65001.into(),
        };
        assert!(announcement.is_announcement());
        assert!(!announcement.is_withdrawal());

        let withdrawal = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 0,
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(192, 0, 2, 0),
            asn: 65001.into(),
        };
        assert!(!withdrawal.is_announcement());
        assert!(withdrawal.is_withdrawal());
    }

    #[test]
    fn test_ipv6_prefix_flags() {
        let announcement = RtrIPv6Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 48,
            max_length: 48,
            prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
            asn: 65001.into(),
        };
        assert!(announcement.is_announcement());
        assert!(!announcement.is_withdrawal());
    }

    #[test]
    fn test_router_key_flags() {
        let announcement = RtrRouterKey {
            version: RtrProtocolVersion::V1,
            flags: 1,
            subject_key_identifier: [0; 20],
            asn: 65001.into(),
            subject_public_key_info: vec![1, 2, 3],
        };
        assert!(announcement.is_announcement());
        assert!(!announcement.is_withdrawal());
    }

    #[test]
    fn test_end_of_data_defaults() {
        assert_eq!(RtrEndOfData::DEFAULT_REFRESH, 3600);
        assert_eq!(RtrEndOfData::DEFAULT_RETRY, 600);
        assert_eq!(RtrEndOfData::DEFAULT_EXPIRE, 7200);

        let eod = RtrEndOfData {
            version: RtrProtocolVersion::V0,
            session_id: 1,
            serial_number: 100,
            refresh_interval: None,
            retry_interval: None,
            expire_interval: None,
        };
        assert_eq!(eod.refresh_interval_or_default(), 3600);
        assert_eq!(eod.retry_interval_or_default(), 600);
        assert_eq!(eod.expire_interval_or_default(), 7200);

        let eod_v1 = RtrEndOfData {
            version: RtrProtocolVersion::V1,
            session_id: 1,
            serial_number: 100,
            refresh_interval: Some(1800),
            retry_interval: Some(300),
            expire_interval: Some(3600),
        };
        assert_eq!(eod_v1.refresh_interval_or_default(), 1800);
        assert_eq!(eod_v1.retry_interval_or_default(), 300);
        assert_eq!(eod_v1.expire_interval_or_default(), 3600);
    }

    #[test]
    fn test_reset_query_constructors() {
        let v1 = RtrResetQuery::new_v1();
        assert_eq!(v1.version, RtrProtocolVersion::V1);

        let v0 = RtrResetQuery::new_v0();
        assert_eq!(v0.version, RtrProtocolVersion::V0);

        let default = RtrResetQuery::default();
        assert_eq!(default.version, RtrProtocolVersion::V1);
    }

    #[test]
    fn test_pdu_enum_type() {
        let pdu = RtrPdu::SerialNotify(RtrSerialNotify {
            version: RtrProtocolVersion::V1,
            session_id: 1,
            serial_number: 100,
        });
        assert_eq!(pdu.pdu_type(), RtrPduType::SerialNotify);
        assert_eq!(pdu.version(), RtrProtocolVersion::V1);
    }

    #[test]
    fn test_pdu_enum_all_types_and_versions() {
        // Test pdu_type() and version() for all PDU variants
        let pdus = vec![
            (
                RtrPdu::SerialNotify(RtrSerialNotify {
                    version: RtrProtocolVersion::V0,
                    session_id: 1,
                    serial_number: 100,
                }),
                RtrPduType::SerialNotify,
                RtrProtocolVersion::V0,
            ),
            (
                RtrPdu::SerialQuery(RtrSerialQuery {
                    version: RtrProtocolVersion::V1,
                    session_id: 2,
                    serial_number: 200,
                }),
                RtrPduType::SerialQuery,
                RtrProtocolVersion::V1,
            ),
            (
                RtrPdu::ResetQuery(RtrResetQuery {
                    version: RtrProtocolVersion::V0,
                }),
                RtrPduType::ResetQuery,
                RtrProtocolVersion::V0,
            ),
            (
                RtrPdu::CacheResponse(RtrCacheResponse {
                    version: RtrProtocolVersion::V1,
                    session_id: 3,
                }),
                RtrPduType::CacheResponse,
                RtrProtocolVersion::V1,
            ),
            (
                RtrPdu::IPv4Prefix(RtrIPv4Prefix {
                    version: RtrProtocolVersion::V0,
                    flags: 1,
                    prefix_length: 24,
                    max_length: 24,
                    prefix: Ipv4Addr::new(10, 0, 0, 0),
                    asn: 65000.into(),
                }),
                RtrPduType::IPv4Prefix,
                RtrProtocolVersion::V0,
            ),
            (
                RtrPdu::IPv6Prefix(RtrIPv6Prefix {
                    version: RtrProtocolVersion::V1,
                    flags: 0,
                    prefix_length: 48,
                    max_length: 64,
                    prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
                    asn: 65001.into(),
                }),
                RtrPduType::IPv6Prefix,
                RtrProtocolVersion::V1,
            ),
            (
                RtrPdu::EndOfData(RtrEndOfData {
                    version: RtrProtocolVersion::V0,
                    session_id: 4,
                    serial_number: 300,
                    refresh_interval: None,
                    retry_interval: None,
                    expire_interval: None,
                }),
                RtrPduType::EndOfData,
                RtrProtocolVersion::V0,
            ),
            (
                RtrPdu::CacheReset(RtrCacheReset {
                    version: RtrProtocolVersion::V1,
                }),
                RtrPduType::CacheReset,
                RtrProtocolVersion::V1,
            ),
            (
                RtrPdu::RouterKey(RtrRouterKey {
                    version: RtrProtocolVersion::V1,
                    flags: 1,
                    subject_key_identifier: [0; 20],
                    asn: 65002.into(),
                    subject_public_key_info: vec![],
                }),
                RtrPduType::RouterKey,
                RtrProtocolVersion::V1,
            ),
            (
                RtrPdu::ErrorReport(RtrErrorReport {
                    version: RtrProtocolVersion::V0,
                    error_code: RtrErrorCode::InternalError,
                    erroneous_pdu: vec![],
                    error_text: String::new(),
                }),
                RtrPduType::ErrorReport,
                RtrProtocolVersion::V0,
            ),
        ];

        for (pdu, expected_type, expected_version) in pdus {
            assert_eq!(pdu.pdu_type(), expected_type);
            assert_eq!(pdu.version(), expected_version);
        }
    }

    #[test]
    fn test_pdu_from_impls() {
        let query = RtrResetQuery::new_v1();
        let pdu: RtrPdu = query.into();
        assert_eq!(pdu.pdu_type(), RtrPduType::ResetQuery);
    }

    #[test]
    fn test_all_pdu_from_impls() {
        // Test From impl for all PDU types
        let notify = RtrSerialNotify {
            version: RtrProtocolVersion::V1,
            session_id: 1,
            serial_number: 100,
        };
        let pdu: RtrPdu = notify.into();
        assert!(matches!(pdu, RtrPdu::SerialNotify(_)));

        let query = RtrSerialQuery::new(RtrProtocolVersion::V1, 1, 100);
        let pdu: RtrPdu = query.into();
        assert!(matches!(pdu, RtrPdu::SerialQuery(_)));

        let response = RtrCacheResponse {
            version: RtrProtocolVersion::V1,
            session_id: 1,
        };
        let pdu: RtrPdu = response.into();
        assert!(matches!(pdu, RtrPdu::CacheResponse(_)));

        let prefix4 = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(10, 0, 0, 0),
            asn: 65000.into(),
        };
        let pdu: RtrPdu = prefix4.into();
        assert!(matches!(pdu, RtrPdu::IPv4Prefix(_)));

        let prefix6 = RtrIPv6Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 48,
            max_length: 48,
            prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
            asn: 65000.into(),
        };
        let pdu: RtrPdu = prefix6.into();
        assert!(matches!(pdu, RtrPdu::IPv6Prefix(_)));

        let eod = RtrEndOfData {
            version: RtrProtocolVersion::V1,
            session_id: 1,
            serial_number: 100,
            refresh_interval: Some(3600),
            retry_interval: Some(600),
            expire_interval: Some(7200),
        };
        let pdu: RtrPdu = eod.into();
        assert!(matches!(pdu, RtrPdu::EndOfData(_)));

        let reset = RtrCacheReset {
            version: RtrProtocolVersion::V1,
        };
        let pdu: RtrPdu = reset.into();
        assert!(matches!(pdu, RtrPdu::CacheReset(_)));

        let key = RtrRouterKey {
            version: RtrProtocolVersion::V1,
            flags: 1,
            subject_key_identifier: [0; 20],
            asn: 65000.into(),
            subject_public_key_info: vec![],
        };
        let pdu: RtrPdu = key.into();
        assert!(matches!(pdu, RtrPdu::RouterKey(_)));

        let error = RtrErrorReport::new(
            RtrProtocolVersion::V1,
            RtrErrorCode::InternalError,
            vec![],
            String::new(),
        );
        let pdu: RtrPdu = error.into();
        assert!(matches!(pdu, RtrPdu::ErrorReport(_)));
    }

    #[test]
    fn test_error_report_constructors() {
        let err = RtrErrorReport::unsupported_version(RtrProtocolVersion::V0, vec![1, 2, 3]);
        assert_eq!(err.error_code, RtrErrorCode::UnsupportedProtocolVersion);
        assert_eq!(err.error_text, "Unsupported protocol version");

        let err = RtrErrorReport::unsupported_pdu_type(RtrProtocolVersion::V1, vec![4, 5, 6]);
        assert_eq!(err.error_code, RtrErrorCode::UnsupportedPduType);
        assert_eq!(err.error_text, "Unsupported PDU type");

        let err = RtrErrorReport::corrupt_data(RtrProtocolVersion::V1, vec![], "test error");
        assert_eq!(err.error_code, RtrErrorCode::CorruptData);
        assert_eq!(err.error_text, "test error");

        let err = RtrErrorReport::new(
            RtrProtocolVersion::V0,
            RtrErrorCode::NoDataAvailable,
            vec![7, 8, 9],
            "Custom error".to_string(),
        );
        assert_eq!(err.version, RtrProtocolVersion::V0);
        assert_eq!(err.error_code, RtrErrorCode::NoDataAvailable);
        assert_eq!(err.erroneous_pdu, vec![7, 8, 9]);
        assert_eq!(err.error_text, "Custom error");
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde_roundtrip() {
        let prefix = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(192, 0, 2, 0),
            asn: 65001.into(),
        };

        let json = serde_json::to_string(&prefix).unwrap();
        let decoded: RtrIPv4Prefix = serde_json::from_str(&json).unwrap();
        assert_eq!(prefix, decoded);
    }

    #[test]
    fn test_try_from_protocol_version() {
        // Test TryFrom<u8> for RtrProtocolVersion
        let v0: Result<RtrProtocolVersion, u8> = 0u8.try_into();
        assert_eq!(v0, Ok(RtrProtocolVersion::V0));

        let v1: Result<RtrProtocolVersion, u8> = 1u8.try_into();
        assert_eq!(v1, Ok(RtrProtocolVersion::V1));

        let invalid: Result<RtrProtocolVersion, u8> = 99u8.try_into();
        assert_eq!(invalid, Err(99u8));

        // Test From<RtrProtocolVersion> for u8
        let byte: u8 = RtrProtocolVersion::V0.into();
        assert_eq!(byte, 0);
        let byte: u8 = RtrProtocolVersion::V1.into();
        assert_eq!(byte, 1);
    }

    #[test]
    fn test_try_from_pdu_type() {
        // Test TryFrom<u8> for RtrPduType
        let serial_notify: Result<RtrPduType, u8> = 0u8.try_into();
        assert_eq!(serial_notify, Ok(RtrPduType::SerialNotify));

        let error_report: Result<RtrPduType, u8> = 10u8.try_into();
        assert_eq!(error_report, Ok(RtrPduType::ErrorReport));

        let invalid: Result<RtrPduType, u8> = 5u8.try_into(); // Type 5 doesn't exist
        assert_eq!(invalid, Err(5u8));

        let invalid: Result<RtrPduType, u8> = 255u8.try_into();
        assert_eq!(invalid, Err(255u8));

        // Test From<RtrPduType> for u8
        let byte: u8 = RtrPduType::SerialNotify.into();
        assert_eq!(byte, 0);
        let byte: u8 = RtrPduType::IPv6Prefix.into();
        assert_eq!(byte, 6);
        let byte: u8 = RtrPduType::ErrorReport.into();
        assert_eq!(byte, 10);
    }

    #[test]
    fn test_try_from_error_code() {
        // Test TryFrom<u16> for RtrErrorCode
        let corrupt: Result<RtrErrorCode, u16> = 0u16.try_into();
        assert_eq!(corrupt, Ok(RtrErrorCode::CorruptData));

        let unexpected: Result<RtrErrorCode, u16> = 8u16.try_into();
        assert_eq!(unexpected, Ok(RtrErrorCode::UnexpectedProtocolVersion));

        let invalid: Result<RtrErrorCode, u16> = 9u16.try_into();
        assert_eq!(invalid, Err(9u16));

        let invalid: Result<RtrErrorCode, u16> = 1000u16.try_into();
        assert_eq!(invalid, Err(1000u16));

        // Test From<RtrErrorCode> for u16
        let code: u16 = RtrErrorCode::CorruptData.into();
        assert_eq!(code, 0);
        let code: u16 = RtrErrorCode::UnexpectedProtocolVersion.into();
        assert_eq!(code, 8);
    }

    #[test]
    fn test_ipv6_prefix_withdrawal() {
        let withdrawal = RtrIPv6Prefix {
            version: RtrProtocolVersion::V1,
            flags: 0, // withdrawal
            prefix_length: 48,
            max_length: 64,
            prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
            asn: 65001.into(),
        };
        assert!(!withdrawal.is_announcement());
        assert!(withdrawal.is_withdrawal());
    }

    #[test]
    fn test_router_key_withdrawal() {
        let withdrawal = RtrRouterKey {
            version: RtrProtocolVersion::V1,
            flags: 0, // withdrawal
            subject_key_identifier: [1; 20],
            asn: 65001.into(),
            subject_public_key_info: vec![0xAB, 0xCD],
        };
        assert!(!withdrawal.is_announcement());
        assert!(withdrawal.is_withdrawal());
    }

    #[test]
    fn test_serial_query_new() {
        let query = RtrSerialQuery::new(RtrProtocolVersion::V0, 12345, 67890);
        assert_eq!(query.version, RtrProtocolVersion::V0);
        assert_eq!(query.session_id, 12345);
        assert_eq!(query.serial_number, 67890);
    }

    #[test]
    fn test_reset_query_new() {
        let v0 = RtrResetQuery::new(RtrProtocolVersion::V0);
        assert_eq!(v0.version, RtrProtocolVersion::V0);

        let v1 = RtrResetQuery::new(RtrProtocolVersion::V1);
        assert_eq!(v1.version, RtrProtocolVersion::V1);
    }

    #[test]
    fn test_protocol_version_default() {
        let default = RtrProtocolVersion::default();
        assert_eq!(default, RtrProtocolVersion::V1);
    }

    #[test]
    fn test_all_error_codes() {
        // Test all error code conversions
        let codes = [
            (0u16, RtrErrorCode::CorruptData),
            (1u16, RtrErrorCode::InternalError),
            (2u16, RtrErrorCode::NoDataAvailable),
            (3u16, RtrErrorCode::InvalidRequest),
            (4u16, RtrErrorCode::UnsupportedProtocolVersion),
            (5u16, RtrErrorCode::UnsupportedPduType),
            (6u16, RtrErrorCode::WithdrawalOfUnknownRecord),
            (7u16, RtrErrorCode::DuplicateAnnouncementReceived),
            (8u16, RtrErrorCode::UnexpectedProtocolVersion),
        ];

        for (value, expected) in codes {
            assert_eq!(RtrErrorCode::from_u16(value), Some(expected));
            assert_eq!(expected.to_u16(), value);
        }
    }

    #[test]
    fn test_all_pdu_types() {
        // Test all PDU type conversions
        let types = [
            (0u8, RtrPduType::SerialNotify),
            (1u8, RtrPduType::SerialQuery),
            (2u8, RtrPduType::ResetQuery),
            (3u8, RtrPduType::CacheResponse),
            (4u8, RtrPduType::IPv4Prefix),
            (6u8, RtrPduType::IPv6Prefix),
            (7u8, RtrPduType::EndOfData),
            (8u8, RtrPduType::CacheReset),
            (9u8, RtrPduType::RouterKey),
            (10u8, RtrPduType::ErrorReport),
        ];

        for (value, expected) in types {
            assert_eq!(RtrPduType::from_u8(value), Some(expected));
            assert_eq!(expected.to_u8(), value);
        }

        // Test that type 5 doesn't exist
        assert_eq!(RtrPduType::from_u8(5), None);
    }
}
