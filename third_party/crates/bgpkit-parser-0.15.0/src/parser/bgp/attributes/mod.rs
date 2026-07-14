mod attr_01_origin;
mod attr_02_17_as_path;
mod attr_03_next_hop;
mod attr_04_med;
mod attr_05_local_pref;
mod attr_07_18_aggregator;
mod attr_08_communities;
mod attr_09_originator;
mod attr_10_13_cluster;
mod attr_14_15_nlri;
mod attr_16_25_extended_communities;
mod attr_23_tunnel_encap;
mod attr_29_linkstate;
mod attr_32_large_communities;
mod attr_35_otc;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use log::{debug, warn};
use std::net::IpAddr;

use crate::models::*;

use crate::error::{BgpValidationWarning, ParserError};
use crate::parser::bgp::attributes::attr_01_origin::{encode_origin, parse_origin};
use crate::parser::bgp::attributes::attr_02_17_as_path::{encode_as_path, parse_as_path};
use crate::parser::bgp::attributes::attr_03_next_hop::{encode_next_hop, parse_next_hop};
use crate::parser::bgp::attributes::attr_04_med::{encode_med, parse_med};
use crate::parser::bgp::attributes::attr_05_local_pref::{encode_local_pref, parse_local_pref};
use crate::parser::bgp::attributes::attr_07_18_aggregator::{encode_aggregator, parse_aggregator};
use crate::parser::bgp::attributes::attr_08_communities::{
    encode_regular_communities, parse_regular_communities,
};
use crate::parser::bgp::attributes::attr_09_originator::{
    encode_originator_id, parse_originator_id,
};
use crate::parser::bgp::attributes::attr_10_13_cluster::{encode_clusters, parse_clusters};
use crate::parser::bgp::attributes::attr_14_15_nlri::{encode_nlri, parse_nlri};
use crate::parser::bgp::attributes::attr_16_25_extended_communities::{
    encode_extended_communities, encode_ipv6_extended_communities, parse_extended_community,
    parse_ipv6_extended_community,
};
use crate::parser::bgp::attributes::attr_23_tunnel_encap::{
    encode_tunnel_encapsulation_attribute, parse_tunnel_encapsulation_attribute,
};
use crate::parser::bgp::attributes::attr_29_linkstate::{
    encode_link_state_attribute, parse_link_state_attribute,
};
use crate::parser::bgp::attributes::attr_32_large_communities::{
    encode_large_communities, parse_large_communities,
};
use crate::parser::bgp::attributes::attr_35_otc::{
    encode_only_to_customer, parse_only_to_customer,
};
use crate::parser::ReadUtils;

/// Validate attribute flags according to RFC 4271 and RFC 7606
fn validate_attribute_flags(
    attr_type: AttrType,
    flags: AttrFlags,
    warnings: &mut Vec<BgpValidationWarning>,
) {
    let expected_flags = match attr_type {
        // Well-known mandatory attributes
        AttrType::ORIGIN | AttrType::AS_PATH | AttrType::NEXT_HOP => AttrFlags::TRANSITIVE,
        // Well-known discretionary attributes
        AttrType::ATOMIC_AGGREGATE => AttrFlags::TRANSITIVE,
        // Optional non-transitive attributes
        AttrType::MULTI_EXIT_DISCRIMINATOR
        | AttrType::ORIGINATOR_ID
        | AttrType::CLUSTER_LIST
        | AttrType::MP_REACHABLE_NLRI
        | AttrType::MP_UNREACHABLE_NLRI => AttrFlags::OPTIONAL,
        // Optional transitive attributes
        AttrType::AGGREGATOR
        | AttrType::AS4_AGGREGATOR
        | AttrType::AS4_PATH
        | AttrType::COMMUNITIES
        | AttrType::EXTENDED_COMMUNITIES
        | AttrType::IPV6_ADDRESS_SPECIFIC_EXTENDED_COMMUNITIES
        | AttrType::LARGE_COMMUNITIES
        | AttrType::ONLY_TO_CUSTOMER => AttrFlags::OPTIONAL | AttrFlags::TRANSITIVE,
        // LOCAL_PREFERENCE is well-known mandatory for IBGP
        AttrType::LOCAL_PREFERENCE => AttrFlags::TRANSITIVE,
        // Unknown or development attributes
        _ => return, // Don't validate unknown attributes
    };

    // Check if flags match expected (ignoring EXTENDED and PARTIAL flags for this check)
    let relevant_flags = flags & (AttrFlags::OPTIONAL | AttrFlags::TRANSITIVE);
    if relevant_flags != expected_flags {
        warnings.push(BgpValidationWarning::AttributeFlagsError {
            attr_type,
            expected_flags: expected_flags.bits(),
            actual_flags: relevant_flags.bits(),
        });
    }

    // Check partial flag constraint
    if flags.contains(AttrFlags::PARTIAL) {
        match attr_type {
            // Partial bit MUST be 0 for well-known attributes and optional non-transitive
            AttrType::ORIGIN
            | AttrType::AS_PATH
            | AttrType::NEXT_HOP
            | AttrType::LOCAL_PREFERENCE
            | AttrType::ATOMIC_AGGREGATE
            | AttrType::MULTI_EXIT_DISCRIMINATOR
            | AttrType::ORIGINATOR_ID
            | AttrType::CLUSTER_LIST
            | AttrType::MP_REACHABLE_NLRI
            | AttrType::MP_UNREACHABLE_NLRI => {
                warnings.push(BgpValidationWarning::AttributeFlagsError {
                    attr_type,
                    expected_flags: expected_flags.bits(),
                    actual_flags: flags.bits(),
                });
            }
            _ => {} // Partial is OK for optional transitive attributes
        }
    }
}

/// Check if an attribute type is well-known mandatory
fn is_well_known_mandatory(attr_type: AttrType) -> bool {
    matches!(
        attr_type,
        AttrType::ORIGIN | AttrType::AS_PATH | AttrType::NEXT_HOP | AttrType::LOCAL_PREFERENCE
    )
}

/// Validate attribute length constraints
fn validate_attribute_length(
    attr_type: AttrType,
    length: usize,
    warnings: &mut Vec<BgpValidationWarning>,
) {
    let expected_length = match attr_type {
        AttrType::ORIGIN => Some(1),
        AttrType::NEXT_HOP => Some(4), // IPv4 next hop
        AttrType::MULTI_EXIT_DISCRIMINATOR => Some(4),
        AttrType::LOCAL_PREFERENCE => Some(4),
        AttrType::ATOMIC_AGGREGATE => Some(0),
        AttrType::ORIGINATOR_ID => Some(4),
        AttrType::ONLY_TO_CUSTOMER => Some(4),
        // Variable length attributes - no fixed constraint
        AttrType::AS_PATH
        | AttrType::AS4_PATH
        | AttrType::AGGREGATOR
        | AttrType::AS4_AGGREGATOR
        | AttrType::COMMUNITIES
        | AttrType::EXTENDED_COMMUNITIES
        | AttrType::IPV6_ADDRESS_SPECIFIC_EXTENDED_COMMUNITIES
        | AttrType::LARGE_COMMUNITIES
        | AttrType::CLUSTER_LIST
        | AttrType::MP_REACHABLE_NLRI
        | AttrType::MP_UNREACHABLE_NLRI => None,
        _ => None, // Unknown attributes
    };

    if let Some(expected) = expected_length {
        if length != expected {
            warnings.push(BgpValidationWarning::AttributeLengthError {
                attr_type,
                expected_length: Some(expected),
                actual_length: length,
            });
        }
    }
}

/// Parse BGP attributes given a slice of u8 and some options.
///
/// The `data: &[u8]` contains the entirety of the attributes bytes, therefore the size of
/// the slice is the total byte length of the attributes section of the message.
pub fn parse_attributes(
    mut data: Bytes,
    asn_len: &AsnLength,
    add_path: bool,
    afi: Option<Afi>,
    safi: Option<Safi>,
    prefixes: Option<&[NetworkPrefix]>,
) -> Result<Attributes, ParserError> {
    let mut attributes: Vec<Attribute> = Vec::with_capacity(20);
    let mut validation_warnings: Vec<BgpValidationWarning> = Vec::new();
    // boolean flags for seen attributes - small dataset in hot loop.
    let mut seen_attributes: [bool; 256] = [false; 256];

    while data.remaining() >= 3 {
        // each attribute is at least 3 bytes: flag(1) + type(1) + length(1)
        // thus the while loop condition is set to be at least 3 bytes to read.

        // has content to read
        let flag = AttrFlags::from_bits_retain(data.read_u8()?);
        let attr_type = data.read_u8()?;
        let attr_length = match flag.contains(AttrFlags::EXTENDED) {
            false => data.read_u8()? as usize,
            true => data.read_u16()? as usize,
        };

        let mut partial = false;
        if flag.contains(AttrFlags::PARTIAL) {
            /*
                https://datatracker.ietf.org/doc/html/rfc4271#section-4.3

            > The third high-order bit (bit 2) of the Attribute Flags octet
            > is the Partial bit.  It defines whether the information
            > contained in the optional transitive attribute is partial (if
            > set to 1) or complete (if set to 0).  For well-known attributes
            > and for optional non-transitive attributes, the Partial bit
            > MUST be set to 0.
            */
            partial = true;
        }

        debug!(
            "reading attribute: type -- {:?}, length -- {}",
            &attr_type, attr_length
        );

        let parsed_attr_type = AttrType::from(attr_type);

        // RFC 7606: Check for duplicate attributes
        if seen_attributes[attr_type as usize] {
            validation_warnings.push(BgpValidationWarning::DuplicateAttribute {
                attr_type: parsed_attr_type,
            });
            // Continue processing - don't skip duplicate for now
        }
        seen_attributes[attr_type as usize] = true;

        // Validate attribute flags and length
        validate_attribute_flags(parsed_attr_type, flag, &mut validation_warnings);
        validate_attribute_length(parsed_attr_type, attr_length, &mut validation_warnings);

        let attr_type = match parsed_attr_type {
            attr_type @ AttrType::Unknown(unknown_type) => {
                // skip pass the remaining bytes of this attribute
                let bytes = data.read_n_bytes(attr_length)?;
                let attr_value = match get_deprecated_attr_type(unknown_type) {
                    Some(t) => {
                        debug!("deprecated attribute type: {} - {}", unknown_type, t);
                        AttributeValue::Deprecated(AttrRaw { attr_type, bytes })
                    }
                    None => {
                        debug!("unknown attribute type: {}", unknown_type);
                        AttributeValue::Unknown(AttrRaw { attr_type, bytes })
                    }
                };

                assert_eq!(attr_type, attr_value.attr_type());
                attributes.push(Attribute {
                    value: attr_value,
                    flag,
                });
                continue;
            }
            t => t,
        };

        let bytes_left = data.remaining();

        if data.remaining() < attr_length {
            warn!(
                "not enough bytes: input bytes left - {}, want to read - {}; skipping",
                bytes_left, attr_length
            );
            // break and return already parsed attributes
            break;
        }

        // we know data has enough bytes to read, so we can split the bytes into a new Bytes object
        data.has_n_remaining(attr_length)?;
        let mut attr_data = data.split_to(attr_length);

        let attr = match attr_type {
            AttrType::ORIGIN => parse_origin(attr_data),
            AttrType::AS_PATH => {
                parse_as_path(attr_data, asn_len).map(|path| AttributeValue::AsPath {
                    path,
                    is_as4: false,
                })
            }
            AttrType::NEXT_HOP => parse_next_hop(attr_data, &afi),
            AttrType::MULTI_EXIT_DISCRIMINATOR => parse_med(attr_data),
            AttrType::LOCAL_PREFERENCE => parse_local_pref(attr_data),
            AttrType::ATOMIC_AGGREGATE => Ok(AttributeValue::AtomicAggregate),
            AttrType::AGGREGATOR => {
                parse_aggregator(attr_data, asn_len).map(|(asn, id)| AttributeValue::Aggregator {
                    asn,
                    id,
                    is_as4: false,
                })
            }
            AttrType::ORIGINATOR_ID => parse_originator_id(attr_data),
            AttrType::CLUSTER_LIST => parse_clusters(attr_data),
            AttrType::MP_REACHABLE_NLRI => {
                parse_nlri(attr_data, &afi, &safi, &prefixes, true, add_path)
            }
            AttrType::MP_UNREACHABLE_NLRI => {
                parse_nlri(attr_data, &afi, &safi, &prefixes, false, add_path)
            }
            AttrType::AS4_PATH => parse_as_path(attr_data, &AsnLength::Bits32)
                .map(|path| AttributeValue::AsPath { path, is_as4: true }),
            AttrType::AS4_AGGREGATOR => {
                parse_aggregator(attr_data, &AsnLength::Bits32).map(|(asn, id)| {
                    AttributeValue::Aggregator {
                        asn,
                        id,
                        is_as4: true,
                    }
                })
            }

            // communities
            AttrType::COMMUNITIES => parse_regular_communities(attr_data),
            AttrType::LARGE_COMMUNITIES => parse_large_communities(attr_data),
            AttrType::EXTENDED_COMMUNITIES => parse_extended_community(attr_data),
            AttrType::IPV6_ADDRESS_SPECIFIC_EXTENDED_COMMUNITIES => {
                parse_ipv6_extended_community(attr_data)
            }
            AttrType::DEVELOPMENT => {
                let mut value = vec![];
                for _i in 0..attr_length {
                    value.push(attr_data.read_u8()?);
                }
                Ok(AttributeValue::Development(value))
            }
            AttrType::ONLY_TO_CUSTOMER => parse_only_to_customer(attr_data),
            AttrType::TUNNEL_ENCAPSULATION => parse_tunnel_encapsulation_attribute(attr_data),
            AttrType::BGP_LS_ATTRIBUTE => parse_link_state_attribute(attr_data),
            _ => Err(ParserError::Unsupported(format!(
                "unsupported attribute type: {attr_type:?}"
            ))),
        };

        match attr {
            Ok(value) => {
                assert_eq!(attr_type, value.attr_type());
                attributes.push(Attribute { value, flag });
            }
            Err(e) => {
                // RFC 7606 error handling
                if partial {
                    // Partial attribute with errors - log warning but continue
                    validation_warnings.push(BgpValidationWarning::PartialAttributeError {
                        attr_type,
                        reason: e.to_string(),
                    });
                    debug!("PARTIAL attribute error: {}", e);
                } else if is_well_known_mandatory(attr_type) {
                    // For well-known mandatory attributes, use "treat-as-withdraw" approach
                    // Don't break parsing, but log warning
                    validation_warnings.push(BgpValidationWarning::MalformedAttributeList {
                        reason: format!(
                            "Well-known mandatory attribute {} parsing failed: {}",
                            u8::from(attr_type),
                            e
                        ),
                    });
                    debug!(
                        "Well-known mandatory attribute parsing failed, treating as withdraw: {}",
                        e
                    );
                } else {
                    // For optional attributes, use "attribute discard" approach
                    validation_warnings.push(BgpValidationWarning::OptionalAttributeError {
                        attr_type,
                        reason: e.to_string(),
                    });
                    debug!("Optional attribute error, discarding: {}", e);
                }
                // Continue parsing in all cases - never break the session
                continue;
            }
        };
    }

    // Check for missing well-known mandatory attributes
    let mandatory_attributes = [
        AttrType::ORIGIN,
        AttrType::AS_PATH,
        AttrType::NEXT_HOP,
        // LOCAL_PREFERENCE is only mandatory for IBGP, so we don't check it here
    ];

    for &mandatory_attr in &mandatory_attributes {
        if !seen_attributes[u8::from(mandatory_attr) as usize] {
            validation_warnings.push(BgpValidationWarning::MissingWellKnownAttribute {
                attr_type: mandatory_attr,
            });
        }
    }

    let mut result = Attributes::from(attributes);
    result.validation_warnings = validation_warnings;
    Ok(result)
}

impl Attribute {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();

        let flag = self.flag.bits();
        let type_code = self.value.attr_type().into();

        bytes.put_u8(flag);
        bytes.put_u8(type_code);

        let value_bytes = match &self.value {
            AttributeValue::Origin(v) => encode_origin(v),
            AttributeValue::AsPath { path, is_as4 } => {
                let four_byte = match is_as4 {
                    true => AsnLength::Bits32,
                    false => match asn_len.is_four_byte() {
                        true => AsnLength::Bits32,
                        false => AsnLength::Bits16,
                    },
                };
                encode_as_path(path, four_byte)
            }
            AttributeValue::NextHop(v) => encode_next_hop(v),
            AttributeValue::MultiExitDiscriminator(v) => encode_med(*v),
            AttributeValue::LocalPreference(v) => encode_local_pref(*v),
            AttributeValue::OnlyToCustomer(v) => encode_only_to_customer(v.into()),
            AttributeValue::AtomicAggregate => Bytes::default(),
            AttributeValue::Aggregator { asn, id, is_as4: _ } => {
                encode_aggregator(asn, &IpAddr::from(*id))
            }
            AttributeValue::Communities(v) => encode_regular_communities(v),
            AttributeValue::ExtendedCommunities(v) => encode_extended_communities(v),
            AttributeValue::LargeCommunities(v) => encode_large_communities(v),
            AttributeValue::Ipv6AddressSpecificExtendedCommunities(v) => {
                encode_ipv6_extended_communities(v)
            }
            AttributeValue::OriginatorId(v) => encode_originator_id(&IpAddr::from(*v)),
            AttributeValue::Clusters(v) => encode_clusters(v),
            AttributeValue::MpReachNlri(v) => encode_nlri(v, true),
            AttributeValue::MpUnreachNlri(v) => encode_nlri(v, false),
            AttributeValue::LinkState(v) => encode_link_state_attribute(v),
            AttributeValue::TunnelEncapsulation(v) => encode_tunnel_encapsulation_attribute(v),
            AttributeValue::Development(v) => Bytes::from(v.to_owned()),
            AttributeValue::Deprecated(v) => Bytes::from(v.bytes.to_owned()),
            AttributeValue::Unknown(v) => Bytes::from(v.bytes.to_owned()),
        };

        match self.is_extended() {
            false => {
                bytes.put_u8(value_bytes.len() as u8);
            }
            true => {
                bytes.put_u16(value_bytes.len() as u16);
            }
        }
        bytes.extend(value_bytes);
        bytes.freeze()
    }
}

impl Attributes {
    pub fn encode(&self, asn_len: AsnLength) -> Bytes {
        let mut bytes = BytesMut::new();
        for attr in &self.inner {
            bytes.extend(attr.encode(asn_len));
        }
        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_unknwon_attribute_type() {
        let data = Bytes::from(vec![0x40, 0xFE, 0x00]);
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;
        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes);
        assert!(attributes.is_ok());
        let attributes = attributes.unwrap();
        assert_eq!(attributes.inner.len(), 1);
        assert_eq!(
            attributes.inner[0].value.attr_type(),
            AttrType::Unknown(254)
        );
    }

    #[test]
    fn test_rfc7606_attribute_flags_error() {
        // Create an ORIGIN attribute with wrong flags (should be transitive, not optional)
        let data = Bytes::from(vec![0x80, 0x01, 0x01, 0x00]); // Optional flag set incorrectly
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        // Should have validation warning for incorrect flags
        assert!(attributes.has_validation_warnings());
        let warnings = attributes.validation_warnings();
        // Will have attribute flags error + missing mandatory attributes
        assert!(!warnings.is_empty());

        match &warnings[0] {
            BgpValidationWarning::AttributeFlagsError { attr_type, .. } => {
                assert_eq!(*attr_type, AttrType::ORIGIN);
            }
            _ => panic!("Expected AttributeFlagsError warning"),
        }
    }

    #[test]
    fn test_rfc7606_missing_mandatory_attribute() {
        // Empty attributes - should have warnings for missing mandatory attributes
        let data = Bytes::from(vec![]);
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        // Should have warnings for missing mandatory attributes
        assert!(attributes.has_validation_warnings());
        let warnings = attributes.validation_warnings();
        assert_eq!(warnings.len(), 3); // ORIGIN, AS_PATH, NEXT_HOP

        for warning in warnings {
            match warning {
                BgpValidationWarning::MissingWellKnownAttribute { attr_type } => {
                    assert!(matches!(
                        attr_type,
                        AttrType::ORIGIN | AttrType::AS_PATH | AttrType::NEXT_HOP
                    ));
                }
                _ => panic!("Expected MissingWellKnownAttribute warning"),
            }
        }
    }

    #[test]
    fn test_rfc7606_duplicate_attribute() {
        // Create two ORIGIN attributes
        let data = Bytes::from(vec![
            0x40, 0x01, 0x01, 0x00, // First ORIGIN attribute
            0x40, 0x01, 0x01, 0x01, // Second ORIGIN attribute (duplicate)
        ]);
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        // Should have warning for duplicate attribute
        assert!(attributes.has_validation_warnings());
        let warnings = attributes.validation_warnings();

        // Should have at least one duplicate attribute warning
        let has_duplicate_warning = warnings
            .iter()
            .any(|w| matches!(w, BgpValidationWarning::DuplicateAttribute { .. }));
        assert!(has_duplicate_warning);
    }

    #[test]
    fn test_attribute_type_boundaries() {
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        // Required attributes for valid BGP message
        const REQUIRED_ATTRS: &[u8] = &[
            0x40, 0x01, 0x01, 0x00, // origin
            0x40, 0x02, 0x00, // as_path
            0x40, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, // next_hop
        ];

        // Test highest (development) attribute type
        let mut data = REQUIRED_ATTRS.to_vec();
        data.extend_from_slice(&[0x40, 0xFF, 0x01, 0x00]); // development
        let data = Bytes::from(data);

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        assert!(attributes.has_attr(AttrType::DEVELOPMENT));
        assert!(!attributes.has_validation_warnings());

        // Test lowest (reserved) attribute type
        let mut data = REQUIRED_ATTRS.to_vec();
        data.extend_from_slice(&[0x40, 0x00, 0x01, 0x01]); // reserved
        let data = Bytes::from(data);

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        // There is a validation warning about the reserved attribute
        assert!(attributes.validation_warnings.iter().any(|vw| {
            matches!(vw, BgpValidationWarning::OptionalAttributeError { attr_type, reason:_ } if *attr_type == AttrType::RESERVED)
        }));
    }

    #[test]
    fn test_rfc7606_attribute_length_error() {
        // Create an ORIGIN attribute with wrong length (should be 1 byte, not 2)
        let data = Bytes::from(vec![0x40, 0x01, 0x02, 0x00, 0x01]);
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        let attributes = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes).unwrap();

        // Should have warning for incorrect attribute length
        assert!(attributes.has_validation_warnings());
        let warnings = attributes.validation_warnings();

        let has_length_warning = warnings
            .iter()
            .any(|w| matches!(w, BgpValidationWarning::AttributeLengthError { .. }));
        assert!(has_length_warning);
    }

    #[test]
    fn test_rfc7606_no_session_reset() {
        // Test that parsing continues even with multiple errors
        let data = Bytes::from(vec![
            0x80, 0x01, 0x02, 0x00, 0x01, // Wrong flags and length for ORIGIN
            0x40, 0x01, 0x01, 0x00, // Duplicate ORIGIN
            0x40, 0xFF, 0x01, 0x00, // Unknown attribute
        ]);
        let asn_len = AsnLength::Bits16;
        let add_path = false;
        let afi = None;
        let safi = None;
        let prefixes = None;

        // Should not panic or return error - RFC 7606 requires continued parsing
        let result = parse_attributes(data, &asn_len, add_path, afi, safi, prefixes);
        assert!(result.is_ok());

        let attributes = result.unwrap();
        assert!(attributes.has_validation_warnings());

        // Should have multiple warnings but parsing should continue
        let warnings = attributes.validation_warnings();
        assert!(!warnings.is_empty());
    }
}
