use crate::models::*;
use crate::parser::bgp::messages::parse_bgp_message;
use crate::parser::bmp::error::ParserBmpError;
use crate::parser::bmp::messages::BmpPeerType;
use bytes::Bytes;
use log::warn;

#[derive(Debug, PartialEq, Clone)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct RouteMonitoring {
    pub bgp_message: BgpMessage,
}

pub fn parse_route_monitoring(
    data: &mut Bytes,
    asn_len: &AsnLength,
    peer_type: Option<&BmpPeerType>,
) -> Result<RouteMonitoring, ParserBmpError> {
    // RFC 9069: Local RIB MUST use 4-byte ASN encoding
    if let Some(BmpPeerType::LocalRib) = peer_type {
        if *asn_len != AsnLength::Bits32 {
            warn!("RFC 9069 violation: Local RIB route monitoring MUST use 4-byte ASN encoding");
        }
    }

    let bgp_update = parse_bgp_message(data, false, asn_len)?;
    Ok(RouteMonitoring {
        bgp_message: bgp_update,
    })
}

impl RouteMonitoring {
    /// Check if the BMP route-monitoring message is an End-of-RIB marker.
    pub fn is_end_of_rib(&self) -> bool {
        if let BgpMessage::Update(u) = &self.bgp_message {
            u.is_end_of_rib()
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_end_of_rib() {
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::default(),
            announced_prefixes: vec![],
        };
        assert!(msg.is_end_of_rib());

        let mon_msg = RouteMonitoring {
            bgp_message: BgpMessage::Update(msg),
        };
        assert!(mon_msg.is_end_of_rib());

        let mon_msg = RouteMonitoring {
            bgp_message: BgpMessage::KeepAlive,
        };
        assert!(!mon_msg.is_end_of_rib());
    }

    #[test]
    fn test_debug() {
        let msg = BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::default(),
            announced_prefixes: vec![],
        };
        let mon_msg = RouteMonitoring {
            bgp_message: BgpMessage::Update(msg),
        };
        #[cfg(feature = "parser")]
        let expected = "RouteMonitoring { bgp_message: Update(BgpUpdateMessage { withdrawn_prefixes: [], attributes: Attributes { inner: [], validation_warnings: [] }, announced_prefixes: [] }) }";
        #[cfg(not(feature = "parser"))]
        let expected = "RouteMonitoring { bgp_message: Update(BgpUpdateMessage { withdrawn_prefixes: [], attributes: Attributes { inner: [] }, announced_prefixes: [] }) }";

        assert_eq!(format!("{mon_msg:?}"), expected);
    }

    // Note: These tests verify that the parser handles LocalRib ASN validation correctly.
    // The actual warning messages are logged via the `log` crate and would appear
    // in production use. For testing purposes, we verify that parsing succeeds
    // and the code paths are exercised.

    #[test]
    fn test_local_rib_with_16bit_asn() {
        // This test verifies that LocalRib route monitoring with 16-bit ASN
        // is parsed successfully. In production, a warning would be logged.

        // Create a simple BGP UPDATE message (End-of-RIB)
        let bgp_update = BgpMessage::Update(BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::default(),
            announced_prefixes: vec![],
        });
        let bgp_bytes = bgp_update.encode(AsnLength::Bits16);

        let mut data = bgp_bytes;
        let asn_len = AsnLength::Bits16; // RFC 9069 violation
        let peer_type = crate::parser::bmp::messages::BmpPeerType::LocalRib;

        let result = parse_route_monitoring(&mut data, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // In production, a warning would be logged about ASN encoding violation
    }

    #[test]
    fn test_local_rib_with_32bit_asn() {
        // This test verifies that LocalRib route monitoring with 32-bit ASN
        // is parsed successfully without warnings.

        // Create a simple BGP UPDATE message (End-of-RIB)
        let bgp_update = BgpMessage::Update(BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::default(),
            announced_prefixes: vec![],
        });
        let bgp_bytes = bgp_update.encode(AsnLength::Bits32);

        let mut data = bgp_bytes;
        let asn_len = AsnLength::Bits32; // RFC 9069 compliant
        let peer_type = crate::parser::bmp::messages::BmpPeerType::LocalRib;

        let result = parse_route_monitoring(&mut data, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // No warning should be logged when using 32-bit ASN
    }

    #[test]
    fn test_non_local_rib_with_16bit_asn() {
        // This test verifies that non-LocalRib route monitoring doesn't trigger
        // LocalRib-specific ASN validation.

        // Create a simple BGP UPDATE message (End-of-RIB)
        let bgp_update = BgpMessage::Update(BgpUpdateMessage {
            withdrawn_prefixes: vec![],
            attributes: Attributes::default(),
            announced_prefixes: vec![],
        });
        let bgp_bytes = bgp_update.encode(AsnLength::Bits16);

        let mut data = bgp_bytes;
        let asn_len = AsnLength::Bits16;
        let peer_type = crate::parser::bmp::messages::BmpPeerType::Global; // Not LocalRib

        let result = parse_route_monitoring(&mut data, &asn_len, Some(&peer_type));

        assert!(result.is_ok(), "Parsing should succeed");
        // No warnings should be logged for non-LocalRib peer types
    }
}
