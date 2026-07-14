use crate::models::*;
use crate::parser::bgp::attributes::attr_03_next_hop::parse_mp_next_hop;
use crate::parser::bgp::attributes::attr_29_linkstate::parse_link_state_nlri;
use crate::parser::{parse_nlri_list, ReadUtils};
use crate::ParserError;
use bytes::{BufMut, Bytes, BytesMut};

use log::warn;

///
/// <https://datatracker.ietf.org/doc/html/rfc4760#section-3>
/// The attribute is encoded as shown below:
/// +---------------------------------------------------------+
/// | Address Family Identifier (2 octets)                    |
/// +---------------------------------------------------------+
/// | Subsequent Address Family Identifier (1 octet)          |
/// +---------------------------------------------------------+
/// | Length of Next Hop Network Address (1 octet)            |
/// +---------------------------------------------------------+
/// | Network Address of Next Hop (variable)                  |
/// +---------------------------------------------------------+
/// | Reserved (1 octet)                                      |
/// +---------------------------------------------------------+
/// | Network Layer Reachability Information (variable)       |
/// +---------------------------------------------------------+
pub fn parse_nlri(
    mut input: Bytes,
    afi: &Option<Afi>,
    safi: &Option<Safi>,
    prefixes: &Option<&[NetworkPrefix]>,
    reachable: bool,        // whether the NLRI is announcements or withdrawals
    additional_paths: bool, // whether the NLRI is part of an additional paths message
) -> Result<AttributeValue, ParserError> {
    let first_byte_zero = input.first().map(|b| *b == 0).unwrap_or(false);

    // read address family
    let afi = match afi {
        Some(afi) => {
            if first_byte_zero {
                input.read_afi()?
            } else {
                afi.to_owned()
            }
        }
        None => input.read_afi()?,
    };
    let safi = match safi {
        Some(safi) => {
            if first_byte_zero {
                input.read_safi()?
            } else {
                safi.to_owned()
            }
        }
        None => input.read_safi()?,
    };

    let mut next_hop = None;
    if reachable {
        let next_hop_length = input.read_u8()? as usize;
        input.has_n_remaining(next_hop_length)?;
        let next_hop_bytes = input.split_to(next_hop_length);
        next_hop = parse_mp_next_hop(next_hop_bytes)?;
    }

    // Handle Link-State NLRI differently from traditional IP prefixes
    let (prefixes, link_state_nlris) =
        if afi == Afi::LinkState && (safi == Safi::LinkState || safi == Safi::LinkStateVpn) {
            // Parse Link-State NLRI
            if reachable {
                // skip reserved byte for reachable NRLI
                if input.read_u8()? != 0 {
                    warn!("NRLI reserved byte not 0");
                }
            }
            let ls_nlri = parse_link_state_nlri(input, afi, safi, next_hop, reachable)?;
            let link_state_list = ls_nlri.link_state_nlris;
            (Vec::new(), link_state_list)
        } else {
            // Parse traditional IP prefixes
            let prefixes = match prefixes {
                Some(pfxs) => {
                    // skip parsing prefixes: https://datatracker.ietf.org/doc/html/rfc6396#section-4.3.4
                    if first_byte_zero {
                        if reachable {
                            // skip reserved byte for reachable NRLI
                            if input.read_u8()? != 0 {
                                warn!("NRLI reserved byte not 0");
                            }
                        }
                        parse_nlri_list(input, additional_paths, &afi)?
                    } else {
                        pfxs.to_vec()
                    }
                }
                None => {
                    if reachable {
                        // skip reserved byte for reachable NRLI
                        if input.read_u8()? != 0 {
                            warn!("NRLI reserved byte not 0");
                        }
                    }
                    parse_nlri_list(input, additional_paths, &afi)?
                }
            };
            (prefixes, None)
        };

    let nlri = Nlri {
        afi,
        safi,
        next_hop,
        prefixes,
        link_state_nlris,
        flowspec_nlris: None,
    };

    match reachable {
        true => Ok(AttributeValue::MpReachNlri(nlri)),
        false => Ok(AttributeValue::MpUnreachNlri(nlri)),
    }
}

/// Encode a NLRI attribute.
pub fn encode_nlri(nlri: &Nlri, reachable: bool) -> Bytes {
    let mut bytes = BytesMut::new();

    // encode address family
    bytes.put_u16(nlri.afi as u16);
    bytes.put_u8(nlri.safi as u8);

    if let Some(next_hop) = &nlri.next_hop {
        if !reachable {
            warn!("NLRI next hop should not be set for unreachable NLRI");
        }
        // encode next hop
        let next_hop_bytes = match next_hop {
            NextHopAddress::Ipv4(ip) => ip.octets().to_vec(),
            NextHopAddress::Ipv6(ip) => ip.octets().to_vec(),
            NextHopAddress::Ipv6LinkLocal(ip1, ip2) => {
                let mut ip_bytes = ip1.octets().to_vec();
                ip_bytes.extend_from_slice(&ip2.octets());
                ip_bytes
            }
            // RFC 8950: VPN-IPv6 next hop (24 bytes)
            NextHopAddress::VpnIpv6(rd, ip) => {
                let mut ip_bytes = rd.0.to_vec(); // 8 bytes RD
                ip_bytes.extend_from_slice(&ip.octets()); // 16 bytes IPv6
                ip_bytes
            }
            // RFC 8950: VPN-IPv6 next hop with link-local (48 bytes)
            NextHopAddress::VpnIpv6LinkLocal(rd1, ip1, rd2, ip2) => {
                let mut ip_bytes = rd1.0.to_vec(); // 8 bytes RD1
                ip_bytes.extend_from_slice(&ip1.octets()); // 16 bytes IPv6
                ip_bytes.extend_from_slice(&rd2.0); // 8 bytes RD2
                ip_bytes.extend_from_slice(&ip2.octets()); // 16 bytes IPv6 link-local
                ip_bytes
            }
        };
        bytes.put_u8(next_hop_bytes.len() as u8);
        bytes.put_slice(&next_hop_bytes);
    }

    // write reserved byte for reachable NRLI
    if reachable {
        bytes.put_u8(0);
    }

    // Handle Link-State NLRI encoding
    if nlri.afi == Afi::LinkState {
        if let Some(link_state_nlris) = &nlri.link_state_nlris {
            // Encode Link-State NLRI entries
            for ls_nlri in link_state_nlris {
                // Encode each Link-State NLRI (this would need a proper implementation)
                // For now, we'll create a placeholder
                bytes.put_u16(ls_nlri.nlri_type as u16);
                bytes.put_u16(0); // Length placeholder - would need actual encoding
            }
        }
    } else {
        // NLRI for traditional IP prefixes
        for prefix in &nlri.prefixes {
            bytes.extend(prefix.encode());
        }
    }

    bytes.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;
    use ipnet::IpNet;
    use std::net::Ipv4Addr;
    use std::str::FromStr;

    #[test]
    fn test_parsing_nlri_simple() {
        let test_bytes = Bytes::from(vec![
            0x00, 0x01, // address family: IPv4
            0x01, // safi: unicast
            0x04, // next hop length: 4
            0xC0, 0x00, 0x02, 0x01, // next hop: 192.0.2.1
            0x00, // reserved
            // NLRI
            0x18, // 24 bits prefix length
            0xC0, 0x00, 0x02, // 192.0.2
        ]);
        let res = parse_nlri(test_bytes, &None, &None, &None, true, false);

        if let Ok(AttributeValue::MpReachNlri(nlri)) = res {
            assert_eq!(nlri.afi, Afi::Ipv4);
            assert_eq!(nlri.safi, Safi::Unicast);
            assert_eq!(
                nlri.next_hop,
                Some(NextHopAddress::Ipv4(
                    Ipv4Addr::from_str("192.0.2.1").unwrap()
                ))
            );
            assert_eq!(
                nlri.prefixes,
                vec![NetworkPrefix::from_str("192.0.2.0/24").unwrap()]
            );
        }
    }

    #[test]
    fn test_parsing_nlri_passed_in_afi() {
        let test_bytes = Bytes::from(vec![
            0x00, 0x01, // address family: IPv4
            0x01, // safi: unicast
            0x04, // next hop length: 4
            0xC0, 0x00, 0x02, 0x01, // next hop: 192.0.2.1
            0x00, // reserved
            // NLRI
            0x18, // 24 bits prefix length
            0xC0, 0x00, 0x02, // 192.0.2
        ]);
        let res = parse_nlri(
            test_bytes,
            &Some(Afi::Ipv4),
            &Some(Safi::Unicast),
            &None,
            true,
            false,
        );

        if let Ok(AttributeValue::MpReachNlri(nlri)) = res {
            assert_eq!(nlri.afi, Afi::Ipv4);
            assert_eq!(nlri.safi, Safi::Unicast);
            assert_eq!(
                nlri.next_hop,
                Some(NextHopAddress::Ipv4(
                    Ipv4Addr::from_str("192.0.2.1").unwrap()
                ))
            );
            assert_eq!(
                nlri.prefixes,
                vec![NetworkPrefix::from_str("192.0.2.0/24").unwrap()]
            );
        }
    }

    #[test]
    fn test_parsing_nlri_errors() {
        // wrong next hop
        let test_bytes = Bytes::from(vec![
            0x00, 0x01, // address family: IPv4
            0x01, // safi: unicast
            0x04, // next hop length: 4
            0xC0, 0x00, 0x02, // next hop: 192.0.2.??
            0x00, // reserved
            // NLRI
            0x18, // 24 bits prefix length
            0xC0, 0x00, 0x02, // 192.0.2
        ]);
        let res = parse_nlri(
            test_bytes,
            &Some(Afi::Ipv4),
            &Some(Safi::Unicast),
            &None,
            true,
            false,
        );
        assert!(res.is_err());
    }

    #[test]
    fn test_parsing_nlri_add_path() {
        let test_bytes = Bytes::from(vec![
            0x00, 0x01, // address family: IPv4
            0x01, // safi: unicast
            0x04, // next hop length: 4
            0xC0, 0x00, 0x02, 0x01, // next hop: 192.0.2.1
            0x00, // reserved
            // NLRI
            0x00, 0x00, 0x00, 0x7B, // path_id: 123
            0x18, // 24 bits prefix length
            0xC0, 0x00, 0x02, // 192.0.2
        ]);
        let res = parse_nlri(test_bytes, &None, &None, &None, true, true);

        if let Ok(AttributeValue::MpReachNlri(nlri)) = res {
            assert_eq!(nlri.afi, Afi::Ipv4);
            assert_eq!(nlri.safi, Safi::Unicast);
            assert_eq!(
                nlri.next_hop,
                Some(NextHopAddress::Ipv4(
                    Ipv4Addr::from_str("192.0.2.1").unwrap()
                ))
            );
            let prefix = NetworkPrefix::new(IpNet::from_str("192.0.2.0/24").unwrap(), Some(123));
            assert_eq!(nlri.prefixes[0], prefix);
            assert_eq!(nlri.prefixes[0].path_id, prefix.path_id);
        } else {
            panic!("Unexpected result: {res:?}");
        }
    }

    #[test]
    fn test_encode_nlri() {
        let nlri = Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: Some(NextHopAddress::Ipv4(
                Ipv4Addr::from_str("10.0.0.1").unwrap(),
            )),
            prefixes: vec![NetworkPrefix {
                prefix: IpNet::from_str("192.0.1.0/24").unwrap(),
                path_id: None,
            }],
            link_state_nlris: None,
            flowspec_nlris: None,
        };
        let bytes = encode_nlri(&nlri, true);
        assert_eq!(
            bytes,
            Bytes::from(vec![
                0x00, 0x01, // address family: IPv4
                0x01, // safi: unicast
                0x04, // next hop length: 4
                0x0A, 0x00, 0x00, 0x01, // next hop:
                0x00, // reserved
                // NLRI
                0x18, // 24 bits prefix length
                0xC0, 0x00, 0x01, // 192.0.1
            ])
        );
        let parsed_nlri = parse_nlri(bytes, &None, &None, &None, true, false).unwrap();
        assert_eq!(parsed_nlri, AttributeValue::MpReachNlri(nlri));

        let nlri = Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: Some(NextHopAddress::Ipv4(
                Ipv4Addr::from_str("10.0.0.1").unwrap(),
            )),
            prefixes: vec![NetworkPrefix {
                prefix: IpNet::from_str("192.0.1.0/24").unwrap(),
                path_id: Some(123),
            }],
            link_state_nlris: None,
            flowspec_nlris: None,
        };
        let bytes = encode_nlri(&nlri, true);
        assert_eq!(
            bytes,
            Bytes::from(vec![
                0x00, 0x01, // address family: IPv4
                0x01, // safi: unicast
                0x04, // next hop length: 4
                0x0A, 0x00, 0x00, 0x01, // next hop:
                0x00, // reserved
                // NLRI
                0x00, 0x00, 0x00, 0x7B, // path_id: 123
                0x18, // 24 bits prefix length
                0xC0, 0x00, 0x01, // 192.0.1
            ])
        );
    }

    #[test]
    fn test_parsing_unreachable_nlri() {
        // Test unreachable NLRI (withdrawals)
        let test_bytes = Bytes::from(vec![
            0x00, 0x01, // address family: IPv4
            0x01, // safi: unicast
            // No next hop for unreachable NLRI
            // No reserved byte for unreachable NLRI
            // NLRI
            0x18, // 24 bits prefix length
            0xC0, 0x00, 0x02, // 192.0.2
        ]);
        let res = parse_nlri(test_bytes, &None, &None, &None, false, false);

        if let Ok(AttributeValue::MpUnreachNlri(nlri)) = res {
            assert_eq!(nlri.afi, Afi::Ipv4);
            assert_eq!(nlri.safi, Safi::Unicast);
            assert_eq!(nlri.next_hop, None);
            assert_eq!(
                nlri.prefixes,
                vec![NetworkPrefix::from_str("192.0.2.0/24").unwrap()]
            );
        } else {
            panic!("Unexpected result: {res:?}");
        }
    }

    #[test]
    fn test_encode_unreachable_nlri() {
        // Test encoding unreachable NLRI (withdrawals)
        let nlri = Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: None,
            prefixes: vec![NetworkPrefix {
                prefix: IpNet::from_str("192.0.1.0/24").unwrap(),
                path_id: None,
            }],
            link_state_nlris: None,
            flowspec_nlris: None,
        };
        let bytes = encode_nlri(&nlri, false);
        assert_eq!(
            bytes,
            Bytes::from(vec![
                0x00, 0x01, // address family: IPv4
                0x01, // safi: unicast
                // No next hop for unreachable NLRI
                // No reserved byte for unreachable NLRI
                // NLRI
                0x18, // 24 bits prefix length
                0xC0, 0x00, 0x01, // 192.0.1
            ])
        );

        // Test that the encoded bytes can be parsed back correctly
        let parsed_nlri = parse_nlri(bytes, &None, &None, &None, false, false).unwrap();
        assert_eq!(parsed_nlri, AttributeValue::MpUnreachNlri(nlri));

        // Test with next_hop set (should be encoded for unreachable NLRI)
        let nlri_with_next_hop = Nlri {
            afi: Afi::Ipv4,
            safi: Safi::Unicast,
            next_hop: Some(NextHopAddress::Ipv4(
                Ipv4Addr::from_str("10.0.0.1").unwrap(),
            )),
            prefixes: vec![NetworkPrefix {
                prefix: IpNet::from_str("192.0.1.0/24").unwrap(),
                path_id: None,
            }],
            link_state_nlris: None,
            flowspec_nlris: None,
        };
        let bytes = encode_nlri(&nlri_with_next_hop, false);
        // The encoded bytes should include the next_hop
        assert_eq!(
            bytes,
            Bytes::from(vec![
                0x00, 0x01, // address family: IPv4
                0x01, // safi: unicast
                0x04, // next hop length: 4
                0x0A, 0x00, 0x00, 0x01, // next hop: 10.0.0.1
                // No reserved byte for unreachable NLRI
                // NLRI
                0x18, // 24 bits prefix length
                0xC0, 0x00, 0x01, // 192.0.1
            ])
        );
    }
}
