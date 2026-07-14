//! BGP Extended Communities Attribute
//!
//! RFC4360: <https://datatracker.ietf.org/doc/html/rfc4360#section-4.5>
//! IANA Codes: <https://www.iana.org/assignments/bgp-extended-communities/bgp-extended-communities.xhtml>

use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;

use bytes::{Buf, BufMut, Bytes, BytesMut};
use std::net::Ipv4Addr;

pub fn parse_extended_community(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    // RFC 4360, section 2: Each Extended Community is encoded as an 8-octet quantity [..]
    let num_communities = input.remaining() / 8;

    let mut communities = Vec::with_capacity(num_communities);

    while input.remaining() > 0 {
        let ec_type_u8 = input.read_u8()?;
        let ec: ExtendedCommunity = match ExtendedCommunityType::from(ec_type_u8) {
            ExtendedCommunityType::TransitiveTwoOctetAs => {
                let sub_type = input.read_u8()?;
                let global = input.read_u16()?;
                let mut local: [u8; 4] = [0; 4];
                input.read_exact(&mut local[..])?;
                ExtendedCommunity::TransitiveTwoOctetAs(TwoOctetAsExtCommunity {
                    subtype: sub_type,
                    global_admin: Asn::new_16bit(global),
                    local_admin: local,
                })
            }
            ExtendedCommunityType::NonTransitiveTwoOctetAs => {
                let sub_type = input.read_u8()?;
                match sub_type {
                    0x06 => {
                        // Flow-Spec Traffic Rate
                        let as_number = input.read_u16()?;
                        let rate_bytes = input.read_u32()?;
                        let rate = f32::from_bits(rate_bytes);
                        ExtendedCommunity::FlowSpecTrafficRate(FlowSpecTrafficRate::new(
                            as_number, rate,
                        ))
                    }
                    0x07 => {
                        // Flow-Spec Traffic Action
                        let as_number = input.read_u16()?;
                        let flags = input.read_u32()?;
                        let terminal = (flags & 0x01) != 0;
                        let sample = (flags & 0x02) != 0;
                        ExtendedCommunity::FlowSpecTrafficAction(FlowSpecTrafficAction::new(
                            as_number, terminal, sample,
                        ))
                    }
                    0x08 => {
                        // Flow-Spec Redirect (same as TwoOctetAsExtCommunity but different variant)
                        let global = input.read_u16()?;
                        let mut local: [u8; 4] = [0; 4];
                        input.read_exact(&mut local)?;
                        ExtendedCommunity::FlowSpecRedirect(TwoOctetAsExtCommunity {
                            subtype: sub_type,
                            global_admin: Asn::new_16bit(global),
                            local_admin: local,
                        })
                    }
                    0x09 => {
                        // Flow-Spec Traffic Marking
                        let as_number = input.read_u16()?;
                        let dscp = input.read_u8()?;
                        let _reserved1 = input.read_u8()?; // reserved
                        let _reserved2 = input.read_u16()?; // reserved
                        ExtendedCommunity::FlowSpecTrafficMarking(FlowSpecTrafficMarking::new(
                            as_number, dscp,
                        ))
                    }
                    _ => {
                        // Standard NonTransitiveTwoOctetAs
                        let global = input.read_u16()?;
                        let mut local: [u8; 4] = [0; 4];
                        input.read_exact(&mut local)?;
                        ExtendedCommunity::NonTransitiveTwoOctetAs(TwoOctetAsExtCommunity {
                            subtype: sub_type,
                            global_admin: Asn::new_16bit(global),
                            local_admin: local,
                        })
                    }
                }
            }

            ExtendedCommunityType::TransitiveIpv4Addr => {
                let sub_type = input.read_u8()?;
                let global = Ipv4Addr::from(input.read_u32()?);
                let mut local: [u8; 2] = [0; 2];
                input.read_exact(&mut local)?;
                ExtendedCommunity::TransitiveIpv4Addr(Ipv4AddrExtCommunity {
                    subtype: sub_type,
                    global_admin: global,
                    local_admin: local,
                })
            }
            ExtendedCommunityType::NonTransitiveIpv4Addr => {
                let sub_type = input.read_u8()?;
                let global = Ipv4Addr::from(input.read_u32()?);
                let mut local: [u8; 2] = [0; 2];
                input.read_exact(&mut local)?;
                ExtendedCommunity::NonTransitiveIpv4Addr(Ipv4AddrExtCommunity {
                    subtype: sub_type,
                    global_admin: global,
                    local_admin: local,
                })
            }
            ExtendedCommunityType::TransitiveFourOctetAs => {
                let sub_type = input.read_u8()?;
                let global = input.read_u32()?;
                let mut local: [u8; 2] = [0; 2];
                input.read_exact(&mut local)?;
                ExtendedCommunity::TransitiveFourOctetAs(FourOctetAsExtCommunity {
                    subtype: sub_type,
                    global_admin: Asn::new_32bit(global),
                    local_admin: local,
                })
            }
            ExtendedCommunityType::NonTransitiveFourOctetAs => {
                let sub_type = input.read_u8()?;
                let global = input.read_u32()?;
                let mut local: [u8; 2] = [0; 2];
                input.read_exact(&mut local)?;
                ExtendedCommunity::NonTransitiveFourOctetAs(FourOctetAsExtCommunity {
                    subtype: sub_type,
                    global_admin: Asn::new_32bit(global),
                    local_admin: local,
                })
            }

            ExtendedCommunityType::TransitiveOpaque => {
                let sub_type = input.read_u8()?;
                let mut value: [u8; 6] = [0; 6];
                input.read_exact(&mut value)?;
                ExtendedCommunity::TransitiveOpaque(OpaqueExtCommunity {
                    subtype: sub_type,
                    value,
                })
            }
            ExtendedCommunityType::NonTransitiveOpaque => {
                let sub_type = input.read_u8()?;
                let mut value: [u8; 6] = [0; 6];
                input.read_exact(&mut value)?;
                ExtendedCommunity::NonTransitiveOpaque(OpaqueExtCommunity {
                    subtype: sub_type,
                    value,
                })
            }
            ExtendedCommunityType::Unknown(_) => {
                let mut buffer: [u8; 8] = [0; 8];
                buffer[0] = ec_type_u8;
                input.read_exact(&mut buffer[1..])?;

                ExtendedCommunity::Raw(buffer)
            }
        };

        communities.push(ec);
    }

    debug_assert!(communities.len() == num_communities);
    Ok(AttributeValue::ExtendedCommunities(communities))
}

pub fn parse_ipv6_extended_community(mut input: Bytes) -> Result<AttributeValue, ParserError> {
    // RFC 5701, section 2: Each IPv6 Address Specific extended community is encoded as a 20-octet quantity [..]
    let num_communities = input.remaining() / 20;

    let mut communities = Vec::with_capacity(num_communities);
    while input.remaining() > 0 {
        let ec_type_u8 = input.read_u8()?;
        let sub_type = input.read_u8()?;
        let global = input.read_ipv6_address()?;
        let mut local: [u8; 2] = [0; 2];
        local[0] = input.read_u8()?;
        local[1] = input.read_u8()?;
        let ec = Ipv6AddrExtCommunity {
            community_type: ExtendedCommunityType::from(ec_type_u8),
            subtype: sub_type,
            global_admin: global,
            local_admin: local,
        };
        communities.push(ec);
    }

    debug_assert!(communities.len() == num_communities);
    Ok(AttributeValue::Ipv6AddressSpecificExtendedCommunities(
        communities,
    ))
}

pub fn encode_extended_communities(communities: &Vec<ExtendedCommunity>) -> Bytes {
    let expected_len = 8 * communities.len();
    let mut bytes = BytesMut::with_capacity(expected_len);

    for community in communities {
        let ec_type = u8::from(community.community_type());
        match community {
            ExtendedCommunity::TransitiveTwoOctetAs(two_octet)
            | ExtendedCommunity::NonTransitiveTwoOctetAs(two_octet) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(two_octet.subtype);
                bytes.put_u16(two_octet.global_admin.into());
                bytes.put_slice(two_octet.local_admin.as_slice());
            }
            ExtendedCommunity::TransitiveIpv4Addr(ipv4)
            | ExtendedCommunity::NonTransitiveIpv4Addr(ipv4) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(ipv4.subtype);
                bytes.put_u32(ipv4.global_admin.into());
                bytes.put_slice(ipv4.local_admin.as_slice());
            }

            ExtendedCommunity::TransitiveFourOctetAs(four_octet)
            | ExtendedCommunity::NonTransitiveFourOctetAs(four_octet) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(four_octet.subtype);
                bytes.put_u32(four_octet.global_admin.into());
                bytes.put_slice(four_octet.local_admin.as_slice());
            }

            ExtendedCommunity::TransitiveOpaque(opaque)
            | ExtendedCommunity::NonTransitiveOpaque(opaque) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(opaque.subtype);
                bytes.put_slice(&opaque.value);
            }

            ExtendedCommunity::FlowSpecTrafficRate(rate) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(0x06); // subtype
                bytes.put_u16(rate.as_number);
                bytes.put_f32(rate.rate_bytes_per_sec);
            }
            ExtendedCommunity::FlowSpecTrafficAction(action) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(0x07); // subtype
                bytes.put_u16(action.as_number);
                let mut flags = 0u32;
                if action.terminal {
                    flags |= 0x01;
                }
                if action.sample {
                    flags |= 0x02;
                }
                bytes.put_u32(flags);
            }
            ExtendedCommunity::FlowSpecRedirect(redirect) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(0x08); // subtype
                bytes.put_u16(redirect.global_admin.into());
                bytes.put_slice(redirect.local_admin.as_slice());
            }
            ExtendedCommunity::FlowSpecTrafficMarking(marking) => {
                bytes.put_u8(ec_type);
                bytes.put_u8(0x09); // subtype
                bytes.put_u16(marking.as_number);
                bytes.put_u8(marking.dscp);
                bytes.put_u8(0); // reserved
                bytes.put_u16(0); // reserved
            }
            ExtendedCommunity::Raw(raw) => {
                bytes.put_slice(raw);
            }
        }
    }

    debug_assert!(bytes.len() == expected_len);
    bytes.freeze()
}

pub fn encode_ipv6_extended_communities(communities: &Vec<Ipv6AddrExtCommunity>) -> Bytes {
    let mut bytes = BytesMut::new();
    for community in communities {
        let ec_type = u8::from(community.community_type);
        bytes.put_u8(ec_type);
        bytes.put_u8(community.subtype);
        bytes.put_u128(community.global_admin.into());
        bytes.put_slice(community.local_admin.as_slice());
    }
    bytes.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv6Addr;

    // TransitiveTwoOctetAsSpecific = 0x00,
    // TransitiveIpv4AddressSpecific = 0x01,
    // TransitiveFourOctetAsSpecific = 0x02,
    // TransitiveOpaque = 0x03,

    #[test]
    fn test_parse_extended_communities_two_octet_as() {
        // test Transitive Two Octet AS Specific
        let data: Vec<u8> = vec![
            0x00, // Transitive Two Octet AS Specific
            0x02, // Route Target
            0x00, 0x01, // AS 1
            0x00, 0x00, 0x00, 0x01, // Local Admin 1
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::TransitiveTwoOctetAs(community) = &communities[0] {
                assert_eq!(community.subtype, 0x02);
                assert_eq!(community.global_admin, Asn::new_16bit(1));
                assert_eq!(community.local_admin, [0x00, 0x00, 0x00, 0x01]);
            }
        }

        // test Nontransitive Two Octet AS Specific
        let data: Vec<u8> = vec![
            0x40, // Nontransitive Two Octet AS Specific
            0x02, // Route Target
            0x00, 0x01, // AS 1
            0x00, 0x00, 0x00, 0x01, // Local Admin 1
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::NonTransitiveTwoOctetAs(community) = &communities[0] {
                assert_eq!(community.subtype, 0x02);
                assert_eq!(community.global_admin, Asn::new_16bit(1));
                assert_eq!(community.local_admin, [0x00, 0x00, 0x00, 0x01]);
            }
        }
    }

    #[test]
    fn test_parse_extended_communities_ipv4() {
        let data: Vec<u8> = vec![
            0x01, // Transitive IPv4 Address Specific
            0x02, // Route Target
            0xC0, 0x00, 0x02, 0x01, // ipv4: 192.0.2.1
            0x00, 0x01, // Local Admin 1
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::TransitiveIpv4Addr(community) = &communities[0] {
                assert_eq!(community.subtype, 0x02);
                assert_eq!(community.global_admin, Ipv4Addr::new(192, 0, 2, 1));
                assert_eq!(community.local_admin, [0x00, 0x01]);
            } else {
                panic!("Unexpected community type");
            }
        } else {
            panic!("Unexpected attribute type");
        }
    }

    #[test]
    fn test_parse_extended_communities_four_octet_as() {
        let data: Vec<u8> = vec![
            0x02, // Transitive Four Octet AS Specific
            0x02, // Route Target
            0x00, 0x00, 0x00, 0x01, // AS 1
            0x00, 0x01, // Local Admin 1
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::TransitiveFourOctetAs(community) = &communities[0] {
                assert_eq!(community.subtype, 0x02);
                assert_eq!(community.global_admin, Asn::new_16bit(1));
                assert_eq!(community.local_admin, [0x00, 0x01]);
            } else {
                panic!("Unexpected community type");
            }
        } else {
            panic!("Unexpected attribute type");
        }
    }

    #[test]
    fn test_parse_extended_communities_opaque() {
        let data: Vec<u8> = vec![
            0x03, // Transitive Opaque
            0x02, // Route Target
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, // Opaque
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::TransitiveOpaque(community) = &communities[0] {
                assert_eq!(community.subtype, 0x02);
                assert_eq!(community.value, [0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
            } else {
                panic!("Unexpected community type");
            }
        } else {
            panic!("Unexpected attribute type");
        }
    }

    #[test]
    fn test_parse_extended_communities_ipv6() {
        let data: Vec<u8> = vec![
            0x40, // Transitive IPv6 Address Specific
            0x02, // Route Target
            0x20, 0x01, 0x0D, 0xB8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, // ipv6: 2001:db8::1
            0x00, 0x01, // Local Admin 1
        ];

        if let AttributeValue::Ipv6AddressSpecificExtendedCommunities(communities) =
            parse_ipv6_extended_community(Bytes::from(data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            let community = communities[0];
            assert_eq!(
                community.community_type,
                ExtendedCommunityType::NonTransitiveTwoOctetAs
            );
            assert_eq!(community.subtype, 0x02);
            assert_eq!(
                community.global_admin,
                Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1)
            );
            assert_eq!(community.local_admin, [0x00, 0x01]);
        } else {
            panic!("Unexpected attribute type");
        }
    }

    #[test]
    fn test_encode_raw_extended_community() {
        let community = ExtendedCommunity::Raw([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
        let bytes = encode_extended_communities(&vec![community]);
        assert_eq!(
            bytes,
            Bytes::from_static(&[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        );
    }

    #[test]
    fn test_encode_ipv6_extended_communites() {
        let community = Ipv6AddrExtCommunity {
            community_type: ExtendedCommunityType::NonTransitiveTwoOctetAs,
            subtype: 0x02,
            global_admin: Ipv6Addr::new(0x2001, 0x0db8, 0, 0, 0, 0, 0, 1),
            local_admin: [0x00, 0x01],
        };
        let _bytes = encode_ipv6_extended_communities(&vec![community]);
    }

    #[test]
    fn test_flowspec_extended_communities() {
        // Test Flow-Spec Traffic Rate community
        let rate_data = vec![
            0x40, // NonTransitiveTwoOctetAs
            0x06, // Traffic Rate subtype
            0xFC, 0x00, // AS 64512
            0x44, 0x7A, 0x00, 0x00, // 1000.0 as IEEE 754 float32
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(rate_data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::FlowSpecTrafficRate(rate) = &communities[0] {
                assert_eq!(rate.as_number, 64512);
                assert_eq!(rate.rate_bytes_per_sec, 1000.0);
            } else {
                panic!("Expected FlowSpecTrafficRate community");
            }
        } else {
            panic!("Expected ExtendedCommunities attribute");
        }

        // Test Flow-Spec Traffic Action community
        let action_data = vec![
            0x40, // NonTransitiveTwoOctetAs
            0x07, // Traffic Action subtype
            0xFC, 0x00, // AS 64512
            0x00, 0x00, 0x00, 0x03, // terminal=1, sample=1
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(action_data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::FlowSpecTrafficAction(action) = &communities[0] {
                assert_eq!(action.as_number, 64512);
                assert!(action.terminal);
                assert!(action.sample);
            } else {
                panic!("Expected FlowSpecTrafficAction community");
            }
        } else {
            panic!("Expected ExtendedCommunities attribute");
        }

        // Test Flow-Spec Traffic Marking community
        let marking_data = vec![
            0x40, // NonTransitiveTwoOctetAs
            0x09, // Traffic Marking subtype
            0xFC, 0x00, // AS 64512
            0x2E, // DSCP 46 (EF)
            0x00, // reserved
            0x00, 0x00, // reserved
        ];

        if let AttributeValue::ExtendedCommunities(communities) =
            parse_extended_community(Bytes::from(marking_data)).unwrap()
        {
            assert_eq!(communities.len(), 1);
            if let ExtendedCommunity::FlowSpecTrafficMarking(marking) = &communities[0] {
                assert_eq!(marking.as_number, 64512);
                assert_eq!(marking.dscp, 46);
            } else {
                panic!("Expected FlowSpecTrafficMarking community");
            }
        } else {
            panic!("Expected ExtendedCommunities attribute");
        }
    }

    #[test]
    fn test_flowspec_extended_communities_encoding() {
        // Test encoding of Flow-Spec communities
        let communities = vec![
            ExtendedCommunity::FlowSpecTrafficRate(FlowSpecTrafficRate::new(64512, 1000.0)),
            ExtendedCommunity::FlowSpecTrafficAction(FlowSpecTrafficAction::new(64512, true, true)),
            ExtendedCommunity::FlowSpecTrafficMarking(FlowSpecTrafficMarking::new(64512, 46)),
        ];

        let encoded = encode_extended_communities(&communities);

        // Parse it back to verify round-trip
        if let AttributeValue::ExtendedCommunities(parsed_communities) =
            parse_extended_community(encoded).unwrap()
        {
            assert_eq!(parsed_communities.len(), 3);

            // Verify traffic rate
            if let ExtendedCommunity::FlowSpecTrafficRate(rate) = &parsed_communities[0] {
                assert_eq!(rate.as_number, 64512);
                assert_eq!(rate.rate_bytes_per_sec, 1000.0);
            } else {
                panic!("Expected FlowSpecTrafficRate community");
            }

            // Verify traffic action
            if let ExtendedCommunity::FlowSpecTrafficAction(action) = &parsed_communities[1] {
                assert_eq!(action.as_number, 64512);
                assert!(action.terminal);
                assert!(action.sample);
            } else {
                panic!("Expected FlowSpecTrafficAction community");
            }

            // Verify traffic marking
            if let ExtendedCommunity::FlowSpecTrafficMarking(marking) = &parsed_communities[2] {
                assert_eq!(marking.as_number, 64512);
                assert_eq!(marking.dscp, 46);
            } else {
                panic!("Expected FlowSpecTrafficMarking community");
            }
        } else {
            panic!("Expected ExtendedCommunities attribute");
        }
    }
}
