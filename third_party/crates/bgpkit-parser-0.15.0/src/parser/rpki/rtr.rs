//! RPKI-to-Router (RTR) Protocol Parser
//!
//! This module provides parsing and encoding functions for RTR protocol PDUs
//! as defined in RFC 6810 (v0) and RFC 8210 (v1).
//!
//! # Parsing
//!
//! ```rust
//! use bgpkit_parser::parser::rpki::rtr::{parse_rtr_pdu, read_rtr_pdu};
//! use bgpkit_parser::models::rpki::rtr::*;
//!
//! // Parse from a byte slice
//! let bytes = [1, 2, 0, 0, 0, 0, 0, 8]; // Reset Query v1
//! let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
//! assert_eq!(consumed, 8);
//! ```
//!
//! # Encoding
//!
//! ```rust
//! use bgpkit_parser::parser::rpki::rtr::RtrEncode;
//! use bgpkit_parser::models::rpki::rtr::*;
//!
//! let query = RtrResetQuery::new_v1();
//! let bytes = query.encode();
//! assert_eq!(bytes.len(), 8);
//! ```

use crate::models::rpki::rtr::*;
use crate::models::Asn;
use std::fmt;
use std::io::{self, Read};
use std::net::{Ipv4Addr, Ipv6Addr};

// =============================================================================
// Error Types
// =============================================================================

/// Errors that can occur during RTR PDU parsing or encoding
#[derive(Debug)]
pub enum RtrError {
    /// I/O error during reading
    IoError(io::Error),
    /// PDU is incomplete (need more data)
    IncompletePdu {
        /// Number of bytes available
        available: usize,
        /// Number of bytes needed
        needed: usize,
    },
    /// Invalid PDU type
    InvalidPduType(u8),
    /// Invalid protocol version
    InvalidProtocolVersion(u8),
    /// Invalid error code
    InvalidErrorCode(u16),
    /// Invalid PDU length
    InvalidLength {
        /// Expected length
        expected: u32,
        /// Actual length in header
        actual: u32,
        /// PDU type
        pdu_type: u8,
    },
    /// Invalid prefix length
    InvalidPrefixLength {
        /// Prefix length
        prefix_len: u8,
        /// Maximum length
        max_len: u8,
        /// Maximum allowed for address family (32 for IPv4, 128 for IPv6)
        max_allowed: u8,
    },
    /// Invalid UTF-8 in error text
    InvalidUtf8,
    /// Router Key PDU in v0 (not supported)
    RouterKeyInV0,
}

impl fmt::Display for RtrError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            RtrError::IoError(e) => write!(f, "I/O error: {}", e),
            RtrError::IncompletePdu { available, needed } => {
                write!(
                    f,
                    "Incomplete PDU: have {} bytes, need {} bytes",
                    available, needed
                )
            }
            RtrError::InvalidPduType(t) => write!(f, "Invalid PDU type: {}", t),
            RtrError::InvalidProtocolVersion(v) => write!(f, "Invalid protocol version: {}", v),
            RtrError::InvalidErrorCode(c) => write!(f, "Invalid error code: {}", c),
            RtrError::InvalidLength {
                expected,
                actual,
                pdu_type,
            } => {
                write!(
                    f,
                    "Invalid length for PDU type {}: expected {}, got {}",
                    pdu_type, expected, actual
                )
            }
            RtrError::InvalidPrefixLength {
                prefix_len,
                max_len,
                max_allowed,
            } => {
                write!(
                    f,
                    "Invalid prefix length: prefix_len={}, max_len={}, max_allowed={}",
                    prefix_len, max_len, max_allowed
                )
            }
            RtrError::InvalidUtf8 => write!(f, "Invalid UTF-8 in error text"),
            RtrError::RouterKeyInV0 => write!(f, "Router Key PDU is not valid in RTR v0"),
        }
    }
}

impl std::error::Error for RtrError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            RtrError::IoError(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for RtrError {
    fn from(e: io::Error) -> Self {
        RtrError::IoError(e)
    }
}

// =============================================================================
// PDU Length Constants
// =============================================================================

/// RTR PDU header length (common to all PDUs)
pub const RTR_HEADER_LEN: usize = 8;

/// Serial Notify PDU length
pub const RTR_SERIAL_NOTIFY_LEN: u32 = 12;

/// Serial Query PDU length
pub const RTR_SERIAL_QUERY_LEN: u32 = 12;

/// Reset Query PDU length
pub const RTR_RESET_QUERY_LEN: u32 = 8;

/// Cache Response PDU length
pub const RTR_CACHE_RESPONSE_LEN: u32 = 8;

/// IPv4 Prefix PDU length
pub const RTR_IPV4_PREFIX_LEN: u32 = 20;

/// IPv6 Prefix PDU length
pub const RTR_IPV6_PREFIX_LEN: u32 = 32;

/// End of Data PDU length (v0)
pub const RTR_END_OF_DATA_V0_LEN: u32 = 12;

/// End of Data PDU length (v1)
pub const RTR_END_OF_DATA_V1_LEN: u32 = 24;

/// Cache Reset PDU length
pub const RTR_CACHE_RESET_LEN: u32 = 8;

/// Router Key PDU minimum length (header(8) + flags(1) + zero(1) + SKI(20) + ASN(4) = 34)
pub const RTR_ROUTER_KEY_MIN_LEN: u32 = 34;

// =============================================================================
// Parsing Functions
// =============================================================================

/// Parse a single RTR PDU from a byte slice.
///
/// Returns the parsed PDU and the number of bytes consumed.
///
/// # Errors
///
/// Returns an error if the input is too short, contains invalid data,
/// or references an unknown PDU type.
///
/// # Example
///
/// ```rust
/// use bgpkit_parser::parser::rpki::rtr::parse_rtr_pdu;
/// use bgpkit_parser::models::rpki::rtr::*;
///
/// // Reset Query PDU (v1)
/// let bytes = [1, 2, 0, 0, 0, 0, 0, 8];
/// let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
/// assert!(matches!(pdu, RtrPdu::ResetQuery(_)));
/// assert_eq!(consumed, 8);
/// ```
pub fn parse_rtr_pdu(input: &[u8]) -> Result<(RtrPdu, usize), RtrError> {
    // Need at least the header
    if input.len() < RTR_HEADER_LEN {
        return Err(RtrError::IncompletePdu {
            available: input.len(),
            needed: RTR_HEADER_LEN,
        });
    }

    // Parse header
    let version_byte = input[0];
    let pdu_type_byte = input[1];
    let session_or_error = u16::from_be_bytes([input[2], input[3]]);
    let length = u32::from_be_bytes([input[4], input[5], input[6], input[7]]);

    // Validate we have enough data
    let length_usize = length as usize;
    if input.len() < length_usize {
        return Err(RtrError::IncompletePdu {
            available: input.len(),
            needed: length_usize,
        });
    }

    // Parse version
    let version = RtrProtocolVersion::from_u8(version_byte)
        .ok_or(RtrError::InvalidProtocolVersion(version_byte))?;

    // Parse PDU type
    let pdu_type =
        RtrPduType::from_u8(pdu_type_byte).ok_or(RtrError::InvalidPduType(pdu_type_byte))?;

    // Parse based on PDU type
    let pdu = match pdu_type {
        RtrPduType::SerialNotify => {
            validate_length(length, RTR_SERIAL_NOTIFY_LEN, pdu_type_byte)?;
            let serial_number = u32::from_be_bytes([input[8], input[9], input[10], input[11]]);
            RtrPdu::SerialNotify(RtrSerialNotify {
                version,
                session_id: session_or_error,
                serial_number,
            })
        }

        RtrPduType::SerialQuery => {
            validate_length(length, RTR_SERIAL_QUERY_LEN, pdu_type_byte)?;
            let serial_number = u32::from_be_bytes([input[8], input[9], input[10], input[11]]);
            RtrPdu::SerialQuery(RtrSerialQuery {
                version,
                session_id: session_or_error,
                serial_number,
            })
        }

        RtrPduType::ResetQuery => {
            validate_length(length, RTR_RESET_QUERY_LEN, pdu_type_byte)?;
            RtrPdu::ResetQuery(RtrResetQuery { version })
        }

        RtrPduType::CacheResponse => {
            validate_length(length, RTR_CACHE_RESPONSE_LEN, pdu_type_byte)?;
            RtrPdu::CacheResponse(RtrCacheResponse {
                version,
                session_id: session_or_error,
            })
        }

        RtrPduType::IPv4Prefix => {
            validate_length(length, RTR_IPV4_PREFIX_LEN, pdu_type_byte)?;
            let flags = input[8];
            let prefix_length = input[9];
            let max_length = input[10];
            // input[11] is reserved/zero

            validate_prefix_length(prefix_length, max_length, 32)?;

            let prefix = Ipv4Addr::new(input[12], input[13], input[14], input[15]);
            let asn = u32::from_be_bytes([input[16], input[17], input[18], input[19]]);

            RtrPdu::IPv4Prefix(RtrIPv4Prefix {
                version,
                flags,
                prefix_length,
                max_length,
                prefix,
                asn: Asn::from(asn),
            })
        }

        RtrPduType::IPv6Prefix => {
            validate_length(length, RTR_IPV6_PREFIX_LEN, pdu_type_byte)?;
            let flags = input[8];
            let prefix_length = input[9];
            let max_length = input[10];
            // input[11] is reserved/zero

            validate_prefix_length(prefix_length, max_length, 128)?;

            let prefix = Ipv6Addr::from([
                input[12], input[13], input[14], input[15], input[16], input[17], input[18],
                input[19], input[20], input[21], input[22], input[23], input[24], input[25],
                input[26], input[27],
            ]);
            let asn = u32::from_be_bytes([input[28], input[29], input[30], input[31]]);

            RtrPdu::IPv6Prefix(RtrIPv6Prefix {
                version,
                flags,
                prefix_length,
                max_length,
                prefix,
                asn: Asn::from(asn),
            })
        }

        RtrPduType::EndOfData => {
            let expected_len = match version {
                RtrProtocolVersion::V0 => RTR_END_OF_DATA_V0_LEN,
                RtrProtocolVersion::V1 => RTR_END_OF_DATA_V1_LEN,
            };
            validate_length(length, expected_len, pdu_type_byte)?;

            let serial_number = u32::from_be_bytes([input[8], input[9], input[10], input[11]]);

            let (refresh_interval, retry_interval, expire_interval) = match version {
                RtrProtocolVersion::V0 => (None, None, None),
                RtrProtocolVersion::V1 => {
                    let refresh = u32::from_be_bytes([input[12], input[13], input[14], input[15]]);
                    let retry = u32::from_be_bytes([input[16], input[17], input[18], input[19]]);
                    let expire = u32::from_be_bytes([input[20], input[21], input[22], input[23]]);
                    (Some(refresh), Some(retry), Some(expire))
                }
            };

            RtrPdu::EndOfData(RtrEndOfData {
                version,
                session_id: session_or_error,
                serial_number,
                refresh_interval,
                retry_interval,
                expire_interval,
            })
        }

        RtrPduType::CacheReset => {
            validate_length(length, RTR_CACHE_RESET_LEN, pdu_type_byte)?;
            RtrPdu::CacheReset(RtrCacheReset { version })
        }

        RtrPduType::RouterKey => {
            // Router Key is v1 only
            if version == RtrProtocolVersion::V0 {
                return Err(RtrError::RouterKeyInV0);
            }

            if length < RTR_ROUTER_KEY_MIN_LEN {
                return Err(RtrError::InvalidLength {
                    expected: RTR_ROUTER_KEY_MIN_LEN,
                    actual: length,
                    pdu_type: pdu_type_byte,
                });
            }

            let flags = input[8];
            // input[9] is zero
            let mut ski = [0u8; 20];
            ski.copy_from_slice(&input[10..30]);
            let asn = u32::from_be_bytes([input[30], input[31], input[32], input[33]]);

            // SPKI is the rest of the PDU (34 bytes of header + fixed fields already parsed)
            let spki_len = (length as usize) - 34;
            let spki = if spki_len > 0 {
                input[34..34 + spki_len].to_vec()
            } else {
                Vec::new()
            };

            RtrPdu::RouterKey(RtrRouterKey {
                version,
                flags,
                subject_key_identifier: ski,
                asn: Asn::from(asn),
                subject_public_key_info: spki,
            })
        }

        RtrPduType::ErrorReport => {
            // Error Report has variable length
            // Minimum: header (8) + length of encapsulated PDU (4) + length of error text (4) = 16
            if length < 16 {
                return Err(RtrError::InvalidLength {
                    expected: 16,
                    actual: length,
                    pdu_type: pdu_type_byte,
                });
            }

            let error_code = RtrErrorCode::from_u16(session_or_error)
                .ok_or(RtrError::InvalidErrorCode(session_or_error))?;

            let encap_pdu_len =
                u32::from_be_bytes([input[8], input[9], input[10], input[11]]) as usize;

            // Validate encapsulated PDU fits
            if 12 + encap_pdu_len + 4 > length_usize {
                return Err(RtrError::InvalidLength {
                    expected: (12 + encap_pdu_len + 4) as u32,
                    actual: length,
                    pdu_type: pdu_type_byte,
                });
            }

            let erroneous_pdu = if encap_pdu_len > 0 {
                input[12..12 + encap_pdu_len].to_vec()
            } else {
                Vec::new()
            };

            let error_text_len_offset = 12 + encap_pdu_len;
            let error_text_len = u32::from_be_bytes([
                input[error_text_len_offset],
                input[error_text_len_offset + 1],
                input[error_text_len_offset + 2],
                input[error_text_len_offset + 3],
            ]) as usize;

            let error_text_offset = error_text_len_offset + 4;
            let error_text = if error_text_len > 0 {
                std::str::from_utf8(&input[error_text_offset..error_text_offset + error_text_len])
                    .map_err(|_| RtrError::InvalidUtf8)?
                    .to_string()
            } else {
                String::new()
            };

            RtrPdu::ErrorReport(RtrErrorReport {
                version,
                error_code,
                erroneous_pdu,
                error_text,
            })
        }
    };

    Ok((pdu, length_usize))
}

/// Read a single RTR PDU from a reader.
///
/// This function reads exactly one complete PDU from the reader.
///
/// # Errors
///
/// Returns an error if reading fails or the PDU is invalid.
///
/// # Example
///
/// ```rust,no_run
/// use std::net::TcpStream;
/// use bgpkit_parser::parser::rpki::rtr::read_rtr_pdu;
///
/// let mut stream = TcpStream::connect("rtr.example.com:8282").unwrap();
/// let pdu = read_rtr_pdu(&mut stream).unwrap();
/// ```
pub fn read_rtr_pdu<R: Read>(reader: &mut R) -> Result<RtrPdu, RtrError> {
    // Read header first
    let mut header = [0u8; RTR_HEADER_LEN];
    reader.read_exact(&mut header)?;

    // Get length from header
    let length = u32::from_be_bytes([header[4], header[5], header[6], header[7]]) as usize;

    if length < RTR_HEADER_LEN {
        return Err(RtrError::InvalidLength {
            expected: RTR_HEADER_LEN as u32,
            actual: length as u32,
            pdu_type: header[1],
        });
    }

    // Allocate buffer for full PDU
    let mut buffer = vec![0u8; length];
    buffer[..RTR_HEADER_LEN].copy_from_slice(&header);

    // Read remaining bytes
    if length > RTR_HEADER_LEN {
        reader.read_exact(&mut buffer[RTR_HEADER_LEN..])?;
    }

    // Parse the complete PDU
    let (pdu, _) = parse_rtr_pdu(&buffer)?;
    Ok(pdu)
}

fn validate_length(actual: u32, expected: u32, pdu_type: u8) -> Result<(), RtrError> {
    if actual != expected {
        Err(RtrError::InvalidLength {
            expected,
            actual,
            pdu_type,
        })
    } else {
        Ok(())
    }
}

fn validate_prefix_length(prefix_len: u8, max_len: u8, max_allowed: u8) -> Result<(), RtrError> {
    if prefix_len > max_len || max_len > max_allowed {
        Err(RtrError::InvalidPrefixLength {
            prefix_len,
            max_len,
            max_allowed,
        })
    } else {
        Ok(())
    }
}

// =============================================================================
// Encoding Trait and Implementations
// =============================================================================

/// Trait for encoding RTR PDUs to bytes
pub trait RtrEncode {
    /// Encode this PDU to a byte vector
    fn encode(&self) -> Vec<u8>;
}

impl RtrEncode for RtrSerialNotify {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_SERIAL_NOTIFY_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::SerialNotify.to_u8());
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&RTR_SERIAL_NOTIFY_LEN.to_be_bytes());
        buf.extend_from_slice(&self.serial_number.to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrSerialQuery {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_SERIAL_QUERY_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::SerialQuery.to_u8());
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&RTR_SERIAL_QUERY_LEN.to_be_bytes());
        buf.extend_from_slice(&self.serial_number.to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrResetQuery {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_RESET_QUERY_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::ResetQuery.to_u8());
        buf.extend_from_slice(&[0, 0]); // zero
        buf.extend_from_slice(&RTR_RESET_QUERY_LEN.to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrCacheResponse {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_CACHE_RESPONSE_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::CacheResponse.to_u8());
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&RTR_CACHE_RESPONSE_LEN.to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrIPv4Prefix {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_IPV4_PREFIX_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::IPv4Prefix.to_u8());
        buf.extend_from_slice(&[0, 0]); // zero
        buf.extend_from_slice(&RTR_IPV4_PREFIX_LEN.to_be_bytes());
        buf.push(self.flags);
        buf.push(self.prefix_length);
        buf.push(self.max_length);
        buf.push(0); // zero
        buf.extend_from_slice(&self.prefix.octets());
        buf.extend_from_slice(&self.asn.to_u32().to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrIPv6Prefix {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_IPV6_PREFIX_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::IPv6Prefix.to_u8());
        buf.extend_from_slice(&[0, 0]); // zero
        buf.extend_from_slice(&RTR_IPV6_PREFIX_LEN.to_be_bytes());
        buf.push(self.flags);
        buf.push(self.prefix_length);
        buf.push(self.max_length);
        buf.push(0); // zero
        buf.extend_from_slice(&self.prefix.octets());
        buf.extend_from_slice(&self.asn.to_u32().to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrEndOfData {
    fn encode(&self) -> Vec<u8> {
        let length = match self.version {
            RtrProtocolVersion::V0 => RTR_END_OF_DATA_V0_LEN,
            RtrProtocolVersion::V1 => RTR_END_OF_DATA_V1_LEN,
        };
        let mut buf = Vec::with_capacity(length as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::EndOfData.to_u8());
        buf.extend_from_slice(&self.session_id.to_be_bytes());
        buf.extend_from_slice(&length.to_be_bytes());
        buf.extend_from_slice(&self.serial_number.to_be_bytes());

        if self.version == RtrProtocolVersion::V1 {
            buf.extend_from_slice(
                &self
                    .refresh_interval
                    .unwrap_or(RtrEndOfData::DEFAULT_REFRESH)
                    .to_be_bytes(),
            );
            buf.extend_from_slice(
                &self
                    .retry_interval
                    .unwrap_or(RtrEndOfData::DEFAULT_RETRY)
                    .to_be_bytes(),
            );
            buf.extend_from_slice(
                &self
                    .expire_interval
                    .unwrap_or(RtrEndOfData::DEFAULT_EXPIRE)
                    .to_be_bytes(),
            );
        }
        buf
    }
}

impl RtrEncode for RtrCacheReset {
    fn encode(&self) -> Vec<u8> {
        let mut buf = Vec::with_capacity(RTR_CACHE_RESET_LEN as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::CacheReset.to_u8());
        buf.extend_from_slice(&[0, 0]); // zero
        buf.extend_from_slice(&RTR_CACHE_RESET_LEN.to_be_bytes());
        buf
    }
}

impl RtrEncode for RtrRouterKey {
    fn encode(&self) -> Vec<u8> {
        let length = RTR_ROUTER_KEY_MIN_LEN + self.subject_public_key_info.len() as u32;
        let mut buf = Vec::with_capacity(length as usize);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::RouterKey.to_u8());
        buf.extend_from_slice(&[0, 0]); // zero (session_id field is zero for Router Key)
        buf.extend_from_slice(&length.to_be_bytes());
        buf.push(self.flags);
        buf.push(0); // zero
        buf.extend_from_slice(&self.subject_key_identifier);
        buf.extend_from_slice(&self.asn.to_u32().to_be_bytes());
        buf.extend_from_slice(&self.subject_public_key_info);
        buf
    }
}

impl RtrEncode for RtrErrorReport {
    fn encode(&self) -> Vec<u8> {
        let error_text_bytes = self.error_text.as_bytes();
        let length = 16 + self.erroneous_pdu.len() + error_text_bytes.len();
        let mut buf = Vec::with_capacity(length);
        buf.push(self.version.to_u8());
        buf.push(RtrPduType::ErrorReport.to_u8());
        buf.extend_from_slice(&self.error_code.to_u16().to_be_bytes());
        buf.extend_from_slice(&(length as u32).to_be_bytes());
        buf.extend_from_slice(&(self.erroneous_pdu.len() as u32).to_be_bytes());
        buf.extend_from_slice(&self.erroneous_pdu);
        buf.extend_from_slice(&(error_text_bytes.len() as u32).to_be_bytes());
        buf.extend_from_slice(error_text_bytes);
        buf
    }
}

impl RtrEncode for RtrPdu {
    fn encode(&self) -> Vec<u8> {
        match self {
            RtrPdu::SerialNotify(p) => p.encode(),
            RtrPdu::SerialQuery(p) => p.encode(),
            RtrPdu::ResetQuery(p) => p.encode(),
            RtrPdu::CacheResponse(p) => p.encode(),
            RtrPdu::IPv4Prefix(p) => p.encode(),
            RtrPdu::IPv6Prefix(p) => p.encode(),
            RtrPdu::EndOfData(p) => p.encode(),
            RtrPdu::CacheReset(p) => p.encode(),
            RtrPdu::RouterKey(p) => p.encode(),
            RtrPdu::ErrorReport(p) => p.encode(),
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reset_query_roundtrip() {
        let query = RtrResetQuery::new_v1();
        let bytes = query.encode();
        assert_eq!(bytes.len(), 8);

        let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
        assert_eq!(consumed, 8);
        assert!(matches!(pdu, RtrPdu::ResetQuery(q) if q.version == RtrProtocolVersion::V1));
    }

    #[test]
    fn test_reset_query_v0_roundtrip() {
        let query = RtrResetQuery::new_v0();
        let bytes = query.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        assert!(matches!(pdu, RtrPdu::ResetQuery(q) if q.version == RtrProtocolVersion::V0));
    }

    #[test]
    fn test_serial_query_roundtrip() {
        let query = RtrSerialQuery::new(RtrProtocolVersion::V1, 12345, 67890);
        let bytes = query.encode();
        assert_eq!(bytes.len(), 12);

        let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
        assert_eq!(consumed, 12);
        match pdu {
            RtrPdu::SerialQuery(q) => {
                assert_eq!(q.session_id, 12345);
                assert_eq!(q.serial_number, 67890);
            }
            _ => panic!("Expected SerialQuery"),
        }
    }

    #[test]
    fn test_serial_notify_roundtrip() {
        let notify = RtrSerialNotify {
            version: RtrProtocolVersion::V1,
            session_id: 100,
            serial_number: 200,
        };
        let bytes = notify.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::SerialNotify(n) => {
                assert_eq!(n.session_id, 100);
                assert_eq!(n.serial_number, 200);
            }
            _ => panic!("Expected SerialNotify"),
        }
    }

    #[test]
    fn test_cache_response_roundtrip() {
        let response = RtrCacheResponse {
            version: RtrProtocolVersion::V1,
            session_id: 42,
        };
        let bytes = response.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::CacheResponse(r) => {
                assert_eq!(r.session_id, 42);
            }
            _ => panic!("Expected CacheResponse"),
        }
    }

    #[test]
    fn test_ipv4_prefix_roundtrip() {
        let prefix = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(192, 0, 2, 0),
            asn: Asn::from(65001u32),
        };
        let bytes = prefix.encode();
        assert_eq!(bytes.len(), 20);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::IPv4Prefix(p) => {
                assert!(p.is_announcement());
                assert_eq!(p.prefix_length, 24);
                assert_eq!(p.max_length, 24);
                assert_eq!(p.prefix, Ipv4Addr::new(192, 0, 2, 0));
                assert_eq!(p.asn.to_u32(), 65001);
            }
            _ => panic!("Expected IPv4Prefix"),
        }
    }

    #[test]
    fn test_ipv4_prefix_withdrawal() {
        let prefix = RtrIPv4Prefix {
            version: RtrProtocolVersion::V1,
            flags: 0, // withdrawal
            prefix_length: 24,
            max_length: 24,
            prefix: Ipv4Addr::new(192, 0, 2, 0),
            asn: Asn::from(65001u32),
        };
        let bytes = prefix.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::IPv4Prefix(p) => {
                assert!(p.is_withdrawal());
                assert!(!p.is_announcement());
            }
            _ => panic!("Expected IPv4Prefix"),
        }
    }

    #[test]
    fn test_ipv6_prefix_roundtrip() {
        let prefix = RtrIPv6Prefix {
            version: RtrProtocolVersion::V1,
            flags: 1,
            prefix_length: 48,
            max_length: 64,
            prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
            asn: Asn::from(65002u32),
        };
        let bytes = prefix.encode();
        assert_eq!(bytes.len(), 32);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::IPv6Prefix(p) => {
                assert!(p.is_announcement());
                assert_eq!(p.prefix_length, 48);
                assert_eq!(p.max_length, 64);
                assert_eq!(p.prefix, Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0));
                assert_eq!(p.asn.to_u32(), 65002);
            }
            _ => panic!("Expected IPv6Prefix"),
        }
    }

    #[test]
    fn test_end_of_data_v0_roundtrip() {
        let eod = RtrEndOfData {
            version: RtrProtocolVersion::V0,
            session_id: 100,
            serial_number: 200,
            refresh_interval: None,
            retry_interval: None,
            expire_interval: None,
        };
        let bytes = eod.encode();
        assert_eq!(bytes.len(), 12);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::EndOfData(e) => {
                assert_eq!(e.version, RtrProtocolVersion::V0);
                assert_eq!(e.session_id, 100);
                assert_eq!(e.serial_number, 200);
                assert_eq!(e.refresh_interval, None);
                assert_eq!(e.retry_interval, None);
                assert_eq!(e.expire_interval, None);
            }
            _ => panic!("Expected EndOfData"),
        }
    }

    #[test]
    fn test_end_of_data_v1_roundtrip() {
        let eod = RtrEndOfData {
            version: RtrProtocolVersion::V1,
            session_id: 100,
            serial_number: 200,
            refresh_interval: Some(1800),
            retry_interval: Some(300),
            expire_interval: Some(3600),
        };
        let bytes = eod.encode();
        assert_eq!(bytes.len(), 24);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::EndOfData(e) => {
                assert_eq!(e.version, RtrProtocolVersion::V1);
                assert_eq!(e.refresh_interval, Some(1800));
                assert_eq!(e.retry_interval, Some(300));
                assert_eq!(e.expire_interval, Some(3600));
            }
            _ => panic!("Expected EndOfData"),
        }
    }

    #[test]
    fn test_end_of_data_v1_with_defaults() {
        let eod = RtrEndOfData {
            version: RtrProtocolVersion::V1,
            session_id: 100,
            serial_number: 200,
            refresh_interval: None, // Will use default when encoding
            retry_interval: None,
            expire_interval: None,
        };
        let bytes = eod.encode();
        assert_eq!(bytes.len(), 24);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::EndOfData(e) => {
                // Since v1 encoding always includes timing, they'll be the defaults
                assert_eq!(e.refresh_interval, Some(3600));
                assert_eq!(e.retry_interval, Some(600));
                assert_eq!(e.expire_interval, Some(7200));
            }
            _ => panic!("Expected EndOfData"),
        }
    }

    #[test]
    fn test_cache_reset_roundtrip() {
        let reset = RtrCacheReset {
            version: RtrProtocolVersion::V1,
        };
        let bytes = reset.encode();
        assert_eq!(bytes.len(), 8);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        assert!(matches!(pdu, RtrPdu::CacheReset(_)));
    }

    #[test]
    fn test_router_key_roundtrip() {
        let key = RtrRouterKey {
            version: RtrProtocolVersion::V1,
            flags: 1,
            subject_key_identifier: [
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
            ],
            asn: Asn::from(65003u32),
            subject_public_key_info: vec![0xAB, 0xCD, 0xEF],
        };
        let bytes = key.encode();
        assert_eq!(bytes.len(), 37); // 34 min + 3 SPKI

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::RouterKey(k) => {
                assert!(k.is_announcement());
                assert_eq!(k.subject_key_identifier[0], 1);
                assert_eq!(k.subject_key_identifier[19], 20);
                assert_eq!(k.asn.to_u32(), 65003);
                assert_eq!(k.subject_public_key_info, vec![0xAB, 0xCD, 0xEF]);
            }
            _ => panic!("Expected RouterKey"),
        }
    }

    #[test]
    fn test_router_key_in_v0_error() {
        // Manually construct a Router Key PDU with v0 version
        let mut bytes = vec![
            0, // version 0
            9, // type 9 (Router Key)
            0, 0, // zero
            0, 0, 0, 34, // length = 34 (minimum)
            1,  // flags
            0,  // zero
        ];
        bytes.extend_from_slice(&[0u8; 20]); // SKI
        bytes.extend_from_slice(&[0, 0, 0, 1]); // ASN

        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::RouterKeyInV0)));
    }

    #[test]
    fn test_error_report_roundtrip() {
        let error = RtrErrorReport {
            version: RtrProtocolVersion::V1,
            error_code: RtrErrorCode::UnsupportedProtocolVersion,
            erroneous_pdu: vec![99, 2, 0, 0, 0, 0, 0, 8], // Some invalid PDU
            error_text: "Test error".to_string(),
        };
        let bytes = error.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::ErrorReport(e) => {
                assert_eq!(e.error_code, RtrErrorCode::UnsupportedProtocolVersion);
                assert_eq!(e.erroneous_pdu, vec![99, 2, 0, 0, 0, 0, 0, 8]);
                assert_eq!(e.error_text, "Test error");
            }
            _ => panic!("Expected ErrorReport"),
        }
    }

    #[test]
    fn test_error_report_empty() {
        let error = RtrErrorReport {
            version: RtrProtocolVersion::V1,
            error_code: RtrErrorCode::InternalError,
            erroneous_pdu: vec![],
            error_text: String::new(),
        };
        let bytes = error.encode();
        assert_eq!(bytes.len(), 16);

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::ErrorReport(e) => {
                assert_eq!(e.error_code, RtrErrorCode::InternalError);
                assert!(e.erroneous_pdu.is_empty());
                assert!(e.error_text.is_empty());
            }
            _ => panic!("Expected ErrorReport"),
        }
    }

    #[test]
    fn test_incomplete_pdu_error() {
        let bytes = [1, 2, 0]; // Too short
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::IncompletePdu { .. })));
    }

    #[test]
    fn test_invalid_pdu_type_error() {
        let bytes = [1, 5, 0, 0, 0, 0, 0, 8]; // Type 5 doesn't exist
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidPduType(5))));
    }

    #[test]
    fn test_invalid_protocol_version_error() {
        let bytes = [99, 2, 0, 0, 0, 0, 0, 8]; // Version 99 doesn't exist
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidProtocolVersion(99))));
    }

    #[test]
    fn test_invalid_length_error() {
        // Reset Query with wrong length - need full buffer to match declared length
        let bytes = [1, 2, 0, 0, 0, 0, 0, 10, 0, 0]; // Length says 10, should be 8
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidLength { .. })));
    }

    #[test]
    fn test_invalid_prefix_length_error() {
        // IPv4 prefix with prefix_len > max_len
        let mut bytes = vec![
            1, // version
            4, // type (IPv4 Prefix)
            0, 0, // zero
            0, 0, 0, 20, // length
            1,  // flags
            25, // prefix_length (25)
            24, // max_length (24) - INVALID: prefix_len > max_len
            0,  // zero
        ];
        bytes.extend_from_slice(&[192, 0, 2, 0]); // prefix
        bytes.extend_from_slice(&[0, 0, 0, 1]); // ASN

        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidPrefixLength { .. })));
    }

    #[test]
    fn test_invalid_max_length_error() {
        // IPv4 prefix with max_len > 32
        let mut bytes = vec![
            1, // version
            4, // type (IPv4 Prefix)
            0, 0, // zero
            0, 0, 0, 20, // length
            1,  // flags
            24, // prefix_length
            33, // max_length (33) - INVALID: > 32 for IPv4
            0,  // zero
        ];
        bytes.extend_from_slice(&[192, 0, 2, 0]); // prefix
        bytes.extend_from_slice(&[0, 0, 0, 1]); // ASN

        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidPrefixLength { .. })));
    }

    #[test]
    fn test_read_rtr_pdu_from_cursor() {
        use std::io::Cursor;

        let query = RtrResetQuery::new_v1();
        let bytes = query.encode();
        let mut cursor = Cursor::new(bytes);

        let pdu = read_rtr_pdu(&mut cursor).unwrap();
        assert!(matches!(pdu, RtrPdu::ResetQuery(_)));
    }

    #[test]
    fn test_pdu_enum_encode() {
        let pdu = RtrPdu::ResetQuery(RtrResetQuery::new_v1());
        let bytes = pdu.encode();
        assert_eq!(bytes.len(), 8);

        let (parsed, _) = parse_rtr_pdu(&bytes).unwrap();
        assert!(matches!(parsed, RtrPdu::ResetQuery(_)));
    }

    #[test]
    fn test_all_pdu_types_roundtrip() {
        // Test that all PDU types can be encoded and decoded
        let pdus: Vec<RtrPdu> = vec![
            RtrPdu::SerialNotify(RtrSerialNotify {
                version: RtrProtocolVersion::V1,
                session_id: 1,
                serial_number: 100,
            }),
            RtrPdu::SerialQuery(RtrSerialQuery::new(RtrProtocolVersion::V1, 1, 100)),
            RtrPdu::ResetQuery(RtrResetQuery::new_v1()),
            RtrPdu::CacheResponse(RtrCacheResponse {
                version: RtrProtocolVersion::V1,
                session_id: 1,
            }),
            RtrPdu::IPv4Prefix(RtrIPv4Prefix {
                version: RtrProtocolVersion::V1,
                flags: 1,
                prefix_length: 24,
                max_length: 24,
                prefix: Ipv4Addr::new(10, 0, 0, 0),
                asn: Asn::from(65000u32),
            }),
            RtrPdu::IPv6Prefix(RtrIPv6Prefix {
                version: RtrProtocolVersion::V1,
                flags: 1,
                prefix_length: 48,
                max_length: 48,
                prefix: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 0),
                asn: Asn::from(65000u32),
            }),
            RtrPdu::EndOfData(RtrEndOfData {
                version: RtrProtocolVersion::V1,
                session_id: 1,
                serial_number: 100,
                refresh_interval: Some(3600),
                retry_interval: Some(600),
                expire_interval: Some(7200),
            }),
            RtrPdu::CacheReset(RtrCacheReset {
                version: RtrProtocolVersion::V1,
            }),
            RtrPdu::RouterKey(RtrRouterKey {
                version: RtrProtocolVersion::V1,
                flags: 1,
                subject_key_identifier: [0; 20],
                asn: Asn::from(65000u32),
                subject_public_key_info: vec![1, 2, 3, 4],
            }),
            RtrPdu::ErrorReport(RtrErrorReport {
                version: RtrProtocolVersion::V1,
                error_code: RtrErrorCode::NoDataAvailable,
                erroneous_pdu: vec![],
                error_text: "No data".to_string(),
            }),
        ];

        for original in pdus {
            let bytes = original.encode();
            let (parsed, consumed) = parse_rtr_pdu(&bytes).unwrap();
            assert_eq!(consumed, bytes.len());
            assert_eq!(parsed.pdu_type(), original.pdu_type());
        }
    }

    #[test]
    fn test_error_display() {
        let err = RtrError::InvalidPduType(42);
        assert!(err.to_string().contains("42"));

        let err = RtrError::IncompletePdu {
            available: 4,
            needed: 8,
        };
        assert!(err.to_string().contains("4"));
        assert!(err.to_string().contains("8"));
    }

    #[test]
    fn test_error_display_all_variants() {
        // Test Display for all RtrError variants
        let io_err = RtrError::IoError(std::io::Error::new(
            std::io::ErrorKind::ConnectionReset,
            "connection reset",
        ));
        assert!(io_err.to_string().contains("I/O error"));

        let incomplete = RtrError::IncompletePdu {
            available: 5,
            needed: 10,
        };
        assert!(incomplete.to_string().contains("Incomplete PDU"));
        assert!(incomplete.to_string().contains("5"));
        assert!(incomplete.to_string().contains("10"));

        let invalid_type = RtrError::InvalidPduType(99);
        assert!(invalid_type.to_string().contains("Invalid PDU type"));
        assert!(invalid_type.to_string().contains("99"));

        let invalid_version = RtrError::InvalidProtocolVersion(5);
        assert!(invalid_version
            .to_string()
            .contains("Invalid protocol version"));
        assert!(invalid_version.to_string().contains("5"));

        let invalid_error_code = RtrError::InvalidErrorCode(100);
        assert!(invalid_error_code
            .to_string()
            .contains("Invalid error code"));
        assert!(invalid_error_code.to_string().contains("100"));

        let invalid_length = RtrError::InvalidLength {
            expected: 20,
            actual: 15,
            pdu_type: 4,
        };
        assert!(invalid_length.to_string().contains("Invalid length"));
        assert!(invalid_length.to_string().contains("20"));
        assert!(invalid_length.to_string().contains("15"));
        assert!(invalid_length.to_string().contains("4"));

        let invalid_prefix = RtrError::InvalidPrefixLength {
            prefix_len: 25,
            max_len: 24,
            max_allowed: 32,
        };
        assert!(invalid_prefix.to_string().contains("Invalid prefix length"));
        assert!(invalid_prefix.to_string().contains("25"));
        assert!(invalid_prefix.to_string().contains("24"));
        assert!(invalid_prefix.to_string().contains("32"));

        let invalid_utf8 = RtrError::InvalidUtf8;
        assert!(invalid_utf8.to_string().contains("Invalid UTF-8"));

        let router_key_v0 = RtrError::RouterKeyInV0;
        assert!(router_key_v0.to_string().contains("Router Key PDU"));
        assert!(router_key_v0.to_string().contains("v0"));
    }

    #[test]
    fn test_error_source() {
        use std::error::Error;

        // IoError should have a source
        let io_err = RtrError::IoError(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "file not found",
        ));
        assert!(io_err.source().is_some());

        // Other errors should not have a source
        let incomplete = RtrError::IncompletePdu {
            available: 1,
            needed: 2,
        };
        assert!(incomplete.source().is_none());

        let invalid_type = RtrError::InvalidPduType(5);
        assert!(invalid_type.source().is_none());

        let invalid_utf8 = RtrError::InvalidUtf8;
        assert!(invalid_utf8.source().is_none());
    }

    #[test]
    fn test_error_from_io_error() {
        let io_err = std::io::Error::new(std::io::ErrorKind::TimedOut, "timeout");
        let rtr_err: RtrError = io_err.into();
        assert!(matches!(rtr_err, RtrError::IoError(_)));
    }

    #[test]
    fn test_read_rtr_pdu_short_length() {
        use std::io::Cursor;

        // PDU with length less than header size
        let bytes = vec![
            1, // version
            2, // type (Reset Query)
            0, 0, // zero
            0, 0, 0, 4, // length = 4 (less than header)
        ];
        let mut cursor = Cursor::new(bytes);
        let result = read_rtr_pdu(&mut cursor);
        assert!(matches!(result, Err(RtrError::InvalidLength { .. })));
    }

    #[test]
    fn test_parse_invalid_error_code() {
        // Error Report with invalid error code
        let bytes = vec![
            1,  // version
            10, // type (Error Report)
            0, 100, // error code = 100 (invalid)
            0, 0, 0, 16, // length = 16 (minimum)
            0, 0, 0, 0, // encapsulated PDU length = 0
            0, 0, 0, 0, // error text length = 0
        ];
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidErrorCode(100))));
    }

    #[test]
    fn test_parse_error_report_invalid_utf8() {
        // Error Report with invalid UTF-8 in error text
        let bytes = vec![
            1,  // version
            10, // type (Error Report)
            0, 0, // error code = 0
            0, 0, 0, 20, // length = 20
            0, 0, 0, 0, // encapsulated PDU length = 0
            0, 0, 0, 4, // error text length = 4
            0xFF, 0xFE, 0xFF, 0xFE, // invalid UTF-8
        ];
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidUtf8)));
    }

    #[test]
    fn test_parse_error_report_truncated() {
        // Error Report with encapsulated PDU length exceeding bounds
        let bytes = vec![
            1,  // version
            10, // type (Error Report)
            0, 0, // error code = 0
            0, 0, 0, 16, // length = 16
            0, 0, 0, 100, // encapsulated PDU length = 100 (too large)
            0, 0, 0, 0, // error text length = 0
        ];
        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidLength { .. })));
    }

    #[test]
    fn test_parse_router_key_empty_spki() {
        // Router Key with no SPKI (minimum length)
        let mut bytes = vec![
            1, // version
            9, // type (Router Key)
            0, 0, // zero
            0, 0, 0, 34, // length = 34 (minimum)
            1,  // flags
            0,  // zero
        ];
        bytes.extend_from_slice(&[0u8; 20]); // SKI
        bytes.extend_from_slice(&[0, 0, 0, 1]); // ASN = 1

        let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
        assert_eq!(consumed, 34);
        match pdu {
            RtrPdu::RouterKey(k) => {
                assert!(k.subject_public_key_info.is_empty());
            }
            _ => panic!("Expected RouterKey"),
        }
    }

    #[test]
    fn test_parse_ipv6_invalid_max_length() {
        // IPv6 prefix with max_len > 128
        let mut bytes = vec![
            1, // version
            6, // type (IPv6 Prefix)
            0, 0, // zero
            0, 0, 0, 32,  // length
            1,   // flags
            64,  // prefix_length
            129, // max_length (129) - INVALID: > 128 for IPv6
            0,   // zero
        ];
        bytes.extend_from_slice(&[0u8; 16]); // prefix
        bytes.extend_from_slice(&[0, 0, 0, 1]); // ASN

        let result = parse_rtr_pdu(&bytes);
        assert!(matches!(result, Err(RtrError::InvalidPrefixLength { .. })));
    }

    #[test]
    fn test_encode_all_pdu_types_v0() {
        // Test encoding v0 PDUs
        let notify = RtrSerialNotify {
            version: RtrProtocolVersion::V0,
            session_id: 100,
            serial_number: 200,
        };
        let bytes = notify.encode();
        assert_eq!(bytes[0], 0); // version 0

        let response = RtrCacheResponse {
            version: RtrProtocolVersion::V0,
            session_id: 300,
        };
        let bytes = response.encode();
        assert_eq!(bytes[0], 0); // version 0

        let reset = RtrCacheReset {
            version: RtrProtocolVersion::V0,
        };
        let bytes = reset.encode();
        assert_eq!(bytes[0], 0); // version 0

        let prefix4 = RtrIPv4Prefix {
            version: RtrProtocolVersion::V0,
            flags: 0,
            prefix_length: 16,
            max_length: 24,
            prefix: Ipv4Addr::new(172, 16, 0, 0),
            asn: Asn::from(64512u32),
        };
        let bytes = prefix4.encode();
        assert_eq!(bytes[0], 0); // version 0
        assert_eq!(bytes.len(), 20);

        let prefix6 = RtrIPv6Prefix {
            version: RtrProtocolVersion::V0,
            flags: 1,
            prefix_length: 32,
            max_length: 48,
            prefix: Ipv6Addr::new(0xfc00, 0, 0, 0, 0, 0, 0, 0),
            asn: Asn::from(64513u32),
        };
        let bytes = prefix6.encode();
        assert_eq!(bytes[0], 0); // version 0
        assert_eq!(bytes.len(), 32);
    }

    #[test]
    fn test_read_multiple_pdus() {
        use std::io::Cursor;

        // Create buffer with two PDUs
        let query1 = RtrResetQuery::new_v1();
        let query2 = RtrSerialQuery::new(RtrProtocolVersion::V1, 100, 200);

        let mut buffer = query1.encode();
        buffer.extend(query2.encode());

        let mut cursor = Cursor::new(buffer);

        // Read first PDU
        let pdu1 = read_rtr_pdu(&mut cursor).unwrap();
        assert!(matches!(pdu1, RtrPdu::ResetQuery(_)));

        // Read second PDU
        let pdu2 = read_rtr_pdu(&mut cursor).unwrap();
        assert!(matches!(pdu2, RtrPdu::SerialQuery(_)));
    }

    #[test]
    fn test_parse_with_extra_bytes() {
        // PDU followed by extra bytes - should only consume PDU length
        let query = RtrResetQuery::new_v1();
        let mut bytes = query.encode();
        bytes.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]); // extra bytes

        let (pdu, consumed) = parse_rtr_pdu(&bytes).unwrap();
        assert!(matches!(pdu, RtrPdu::ResetQuery(_)));
        assert_eq!(consumed, 8); // Only consumed the PDU, not extra bytes
    }

    #[test]
    fn test_error_report_with_pdu_and_text() {
        // Full error report with both encapsulated PDU and error text
        let error = RtrErrorReport {
            version: RtrProtocolVersion::V1,
            error_code: RtrErrorCode::CorruptData,
            erroneous_pdu: vec![1, 2, 3, 4, 5, 6, 7, 8], // 8 bytes
            error_text: "Something went wrong!".to_string(), // 21 bytes
        };
        let bytes = error.encode();

        let (pdu, _) = parse_rtr_pdu(&bytes).unwrap();
        match pdu {
            RtrPdu::ErrorReport(e) => {
                assert_eq!(e.error_code, RtrErrorCode::CorruptData);
                assert_eq!(e.erroneous_pdu, vec![1, 2, 3, 4, 5, 6, 7, 8]);
                assert_eq!(e.error_text, "Something went wrong!");
            }
            _ => panic!("Expected ErrorReport"),
        }
    }
}
