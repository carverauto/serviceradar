use crate::models::*;
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{Bytes, BytesMut};
use std::net::IpAddr;

pub fn parse_next_hop(mut input: Bytes, afi: &Option<Afi>) -> Result<AttributeValue, ParserError> {
    if let Some(afi) = afi {
        Ok(input.read_address(afi).map(AttributeValue::NextHop)?)
    } else {
        Ok(input
            .read_address(&Afi::Ipv4)
            .map(AttributeValue::NextHop)?)
    }
}

pub fn parse_mp_next_hop(mut input: Bytes) -> Result<Option<NextHopAddress>, ParserError> {
    let output = match input.len() {
        0 => None,
        4 => Some(input.read_ipv4_address().map(NextHopAddress::Ipv4)?),
        16 => Some(input.read_ipv6_address().map(NextHopAddress::Ipv6)?),
        // RFC 8950: VPN-IPv6 next hop (8-byte RD + 16-byte IPv6)
        24 => {
            let rd_bytes = input.read_n_bytes(8)?;
            let mut rd_array = [0u8; 8];
            rd_array.copy_from_slice(&rd_bytes);
            let rd = RouteDistinguisher(rd_array);
            let ipv6 = input.read_ipv6_address()?;
            Some(NextHopAddress::VpnIpv6(rd, ipv6))
        }
        32 => Some(NextHopAddress::Ipv6LinkLocal(
            input.read_ipv6_address()?,
            input.read_ipv6_address()?,
        )),
        // RFC 8950: VPN-IPv6 next hop with link-local (8-byte RD + 16-byte IPv6 + 8-byte RD + 16-byte IPv6 link-local)
        48 => {
            let rd1_bytes = input.read_n_bytes(8)?;
            let mut rd1_array = [0u8; 8];
            rd1_array.copy_from_slice(&rd1_bytes);
            let rd1 = RouteDistinguisher(rd1_array);
            let ipv6 = input.read_ipv6_address()?;

            let rd2_bytes = input.read_n_bytes(8)?;
            let mut rd2_array = [0u8; 8];
            rd2_array.copy_from_slice(&rd2_bytes);
            let rd2 = RouteDistinguisher(rd2_array);
            let ipv6_link_local = input.read_ipv6_address()?;

            Some(NextHopAddress::VpnIpv6LinkLocal(
                rd1,
                ipv6,
                rd2,
                ipv6_link_local,
            ))
        }
        v => {
            return Err(ParserError::ParseError(format!(
                "Invalid next hop length found: {v}"
            )));
        }
    };
    Ok(output)
}

pub fn encode_next_hop(addr: &IpAddr) -> Bytes {
    match addr {
        IpAddr::V4(n) => Bytes::from(n.octets().to_vec()),
        IpAddr::V6(n) => Bytes::from(n.octets().to_vec()),
    }
}

#[allow(unused_variables, dead_code)]
pub fn encode_mp_next_hop(n: &NextHopAddress) -> Bytes {
    match n {
        NextHopAddress::Ipv4(n) => Bytes::from(n.octets().to_vec()),
        NextHopAddress::Ipv6(n) => Bytes::from(n.octets().to_vec()),
        NextHopAddress::Ipv6LinkLocal(n1, n2) => {
            let mut output = BytesMut::with_capacity(32);
            output.extend(n1.octets().to_vec());
            output.extend(n2.octets().to_vec());
            output.freeze()
        }
        // RFC 8950: VPN-IPv6 next hop (24 bytes)
        NextHopAddress::VpnIpv6(rd, ipv6) => {
            let mut output = BytesMut::with_capacity(24);
            output.extend(rd.0.to_vec()); // 8 bytes RD
            output.extend(ipv6.octets().to_vec()); // 16 bytes IPv6
            output.freeze()
        }
        // RFC 8950: VPN-IPv6 next hop with link-local (48 bytes)
        NextHopAddress::VpnIpv6LinkLocal(rd1, ipv6, rd2, ipv6_link_local) => {
            let mut output = BytesMut::with_capacity(48);
            output.extend(rd1.0.to_vec()); // 8 bytes RD1
            output.extend(ipv6.octets().to_vec()); // 16 bytes IPv6
            output.extend(rd2.0.to_vec()); // 8 bytes RD2
            output.extend(ipv6_link_local.octets().to_vec()); // 16 bytes IPv6 link-local
            output.freeze()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::BytesMut;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::str::FromStr;

    #[test]
    fn test_parse_next_hop() {
        let ipv4 = Ipv4Addr::from_str("10.0.0.1").unwrap();
        let ipv6 = Ipv6Addr::from_str("FC00::1").unwrap();
        let ipv4_bytes = Bytes::from(ipv4.octets().to_vec());
        let ipv6_bytes = Bytes::from(ipv6.octets().to_vec());

        let res = parse_next_hop(ipv4_bytes, &None).unwrap();
        if let AttributeValue::NextHop(n) = res {
            assert_eq!(n.to_string(), "10.0.0.1".to_string())
        }

        let res = parse_next_hop(ipv6_bytes, &Some(Afi::Ipv6)).unwrap();
        if let AttributeValue::NextHop(n) = res {
            assert_eq!(n.to_string().to_ascii_uppercase(), "FC00::1".to_string())
        }
    }

    #[test]
    fn test_encode_next_hop() {
        let ipv4 = Ipv4Addr::from_str("10.0.0.1").unwrap();
        let ipv6 = Ipv6Addr::from_str("FC00::1").unwrap();
        let ipv4_bytes = Bytes::from(ipv4.octets().to_vec());
        let ipv6_bytes = Bytes::from(ipv6.octets().to_vec());

        let _res = parse_next_hop(ipv4_bytes.clone(), &None).unwrap();
        assert_eq!(ipv4_bytes, encode_next_hop(&ipv4.into()));
        let _res = parse_next_hop(ipv6_bytes.clone(), &None).unwrap();
        assert_eq!(ipv6_bytes, encode_next_hop(&ipv6.into()));
    }

    #[test]
    fn test_parse_mp_next_hop() {
        let ipv4 = Bytes::from(Ipv4Addr::from_str("10.0.0.1").unwrap().octets().to_vec());
        let ipv6 = Bytes::from(Ipv6Addr::from_str("fc00::1").unwrap().octets().to_vec());
        let ipv6_2 = Bytes::from(Ipv6Addr::from_str("fc00::2").unwrap().octets().to_vec());

        if let Some(NextHopAddress::Ipv4(n)) = parse_mp_next_hop(ipv4).unwrap() {
            assert_eq!(n.to_string(), "10.0.0.1".to_string())
        }

        if let Some(NextHopAddress::Ipv6(n)) = parse_mp_next_hop(ipv6.clone()).unwrap() {
            assert_eq!(n.to_string(), "fc00::1".to_string())
        }

        let mut combined = BytesMut::from(ipv6.to_vec().as_slice());
        combined.extend_from_slice(&ipv6_2);

        if let Some(NextHopAddress::Ipv6LinkLocal(n, m)) =
            parse_mp_next_hop(combined.into()).unwrap()
        {
            assert_eq!(n.to_string(), "fc00::1".to_string());
            assert_eq!(m.to_string(), "fc00::2".to_string());
        }
    }

    #[test]
    fn test_encode_mp_next_hop() {
        let ipv4 = Bytes::from(Ipv4Addr::from_str("10.0.0.1").unwrap().octets().to_vec());
        let next_hop = parse_mp_next_hop(ipv4.clone()).unwrap().unwrap();
        let bytes = encode_mp_next_hop(&next_hop);
        assert_eq!(bytes, ipv4);

        let ipv6 = Bytes::from(Ipv6Addr::from_str("fc00::1").unwrap().octets().to_vec());
        let next_hop = parse_mp_next_hop(ipv6.clone()).unwrap().unwrap();
        let bytes = encode_mp_next_hop(&next_hop);
        assert_eq!(bytes, ipv6);

        let ipv6_2 = Bytes::from(Ipv6Addr::from_str("fc00::2").unwrap().octets().to_vec());
        let next_hop = parse_mp_next_hop(ipv6.clone()).unwrap().unwrap();
        let bytes = encode_mp_next_hop(&next_hop);
        assert_eq!(bytes, ipv6);

        let mut combined = BytesMut::from(ipv6.to_vec().as_slice());
        combined.extend_from_slice(&ipv6_2);
        let next_hop = parse_mp_next_hop(combined.clone().into()).unwrap().unwrap();
        let bytes = encode_mp_next_hop(&next_hop);
        assert_eq!(bytes, combined);

        // parse empty bytes
        let next_hop = parse_mp_next_hop(Bytes::new()).unwrap();
        assert!(next_hop.is_none());

        // parse invalid bytes
        let next_hop = parse_mp_next_hop(Bytes::from(vec![1]));
        assert!(next_hop.is_err());
    }

    #[test]
    fn test_parse_vpn_next_hop() {
        // Test 24-byte VPN-IPv6 next hop (RFC 8950)
        let vpn_ipv6_bytes = vec![
            // 8-byte Route Distinguisher
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            // 16-byte IPv6 address (2001:db8::1)
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ];

        let next_hop = parse_mp_next_hop(Bytes::from(vpn_ipv6_bytes.clone())).unwrap();
        if let Some(NextHopAddress::VpnIpv6(rd, ipv6)) = next_hop {
            assert_eq!(rd.0, [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
            assert_eq!(ipv6.to_string(), "2001:db8::1");
        } else {
            panic!("Expected VpnIpv6 next hop");
        }

        // Test encoding round-trip
        let encoded = encode_mp_next_hop(&next_hop.unwrap());
        assert_eq!(encoded.to_vec(), vpn_ipv6_bytes);

        // Test 48-byte VPN-IPv6 next hop with link-local (RFC 8950)
        let vpn_ipv6_link_local_bytes = vec![
            // 8-byte Route Distinguisher 1
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            // 16-byte IPv6 address (2001:db8::1)
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01, // 8-byte Route Distinguisher 2
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
            // 16-byte IPv6 link-local address (fe80::1)
            0xfe, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ];

        let next_hop = parse_mp_next_hop(Bytes::from(vpn_ipv6_link_local_bytes.clone())).unwrap();
        if let Some(NextHopAddress::VpnIpv6LinkLocal(rd1, ipv6, rd2, ipv6_ll)) = next_hop {
            assert_eq!(rd1.0, [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]);
            assert_eq!(ipv6.to_string(), "2001:db8::1");
            assert_eq!(rd2.0, [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17]);
            assert_eq!(ipv6_ll.to_string(), "fe80::1");
        } else {
            panic!("Expected VpnIpv6LinkLocal next hop");
        }

        // Test encoding round-trip
        let encoded = encode_mp_next_hop(&next_hop.unwrap());
        assert_eq!(encoded.to_vec(), vpn_ipv6_link_local_bytes);
    }
}
