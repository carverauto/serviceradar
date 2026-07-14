//! RFC 6397: GEO_PEER_TABLE parsing for MRT TABLE_DUMP_V2 format

use crate::error::ParserError;
use crate::models::*;
use crate::parser::ReadUtils;
use bytes::{Buf, BufMut, Bytes, BytesMut};
use std::net::IpAddr;

/// Parse GEO_PEER_TABLE message according to RFC 6397
///
/// ```text
/// The GEO_PEER_TABLE is encoded as follows:
///
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                      Collector BGP ID                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |       View Name Length        |     View Name (variable)      |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                    Collector Latitude                         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                    Collector Longitude                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |          Peer Count           |   Peer Entries (variable)     |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
///
/// Each Peer Entry is encoded as:
///
/// ```text
///  0                   1                   2                   3
///  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |   Peer Type   |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                         Peer BGP ID                          |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                    Peer IP Address (variable)                |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                        Peer AS (variable)                    |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                        Peer Latitude                         |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// |                        Peer Longitude                        |
/// +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
/// ```
pub fn parse_geo_peer_table(data: &mut Bytes) -> Result<GeoPeerTable, ParserError> {
    // Read collector BGP ID (4 bytes)
    let collector_bgp_id = data.read_ipv4_address()?;

    // Read view name length and view name
    let view_name_len = data.read_u16()? as usize;
    let view_name = data.read_n_bytes_to_string(view_name_len)?;

    // Read collector coordinates (4 bytes each, 32-bit float)
    data.has_n_remaining(4)?;
    let collector_latitude = data.get_f32();
    data.has_n_remaining(4)?;
    let collector_longitude = data.get_f32();

    let mut geo_table = GeoPeerTable::new(
        collector_bgp_id,
        view_name,
        collector_latitude,
        collector_longitude,
    );

    // Read peer count
    let peer_count = data.read_u16()?;

    // Parse each peer entry
    for _ in 0..peer_count {
        // Read peer type (1 byte)
        let peer_type_raw = data.read_u8()?;
        let peer_type = PeerType::from_bits_retain(peer_type_raw);

        // Read peer BGP ID (4 bytes)
        let peer_bgp_id = data.read_ipv4_address()?;

        // Read peer IP address (4 or 16 bytes depending on address family)
        let peer_ip: IpAddr = if peer_type.contains(PeerType::ADDRESS_FAMILY_IPV6) {
            data.read_ipv6_address()?.into()
        } else {
            data.read_ipv4_address()?.into()
        };

        // Read peer AS number (2 or 4 bytes depending on AS size)
        let peer_asn = if peer_type.contains(PeerType::AS_SIZE_32BIT) {
            Asn::new_32bit(data.read_u32()?)
        } else {
            Asn::new_16bit(data.read_u16()?)
        };

        // Create the peer structure
        let peer = Peer {
            peer_type,
            peer_bgp_id,
            peer_ip,
            peer_asn,
        };

        // Read peer coordinates (4 bytes each, 32-bit float)
        data.has_n_remaining(4)?;
        let peer_latitude = data.get_f32();
        data.has_n_remaining(4)?;
        let peer_longitude = data.get_f32();

        let geo_peer = GeoPeer::new(peer, peer_latitude, peer_longitude);
        geo_table.add_geo_peer(geo_peer);
    }

    Ok(geo_table)
}

impl GeoPeerTable {
    /// Encode the GEO_PEER_TABLE into bytes according to RFC 6397
    ///
    /// # Returns
    ///
    /// A `Bytes` object containing the encoded GEO_PEER_TABLE data.
    ///
    /// # Example
    ///
    /// ```
    /// use std::net::Ipv4Addr;
    /// use std::str::FromStr;
    /// use bgpkit_parser::models::{GeoPeerTable, GeoPeer, Peer, Asn};
    ///
    /// let mut geo_table = GeoPeerTable::new(
    ///     Ipv4Addr::from_str("10.0.0.1").unwrap(),
    ///     "test-view".to_string(),
    ///     51.5074,  // London latitude
    ///     -0.1278,  // London longitude
    /// );
    ///
    /// let encoded = geo_table.encode();
    /// ```
    pub fn encode(&self) -> Bytes {
        let mut buf = BytesMut::new();

        // Encode collector BGP ID (4 bytes)
        buf.put_u32(self.collector_bgp_id.into());

        // Encode view name length and view name
        let view_name_bytes = self.view_name.as_bytes();
        buf.put_u16(view_name_bytes.len() as u16);
        buf.extend(view_name_bytes);

        // Encode collector coordinates (4 bytes each, 32-bit float)
        buf.put_f32(self.collector_latitude);
        buf.put_f32(self.collector_longitude);

        // Encode peer count
        buf.put_u16(self.geo_peers.len() as u16);

        // Encode each peer entry
        for geo_peer in &self.geo_peers {
            // Encode peer type (1 byte)
            buf.put_u8(geo_peer.peer.peer_type.bits());

            // Encode peer BGP ID (4 bytes)
            buf.put_u32(geo_peer.peer.peer_bgp_id.into());

            // Encode peer IP address (4 or 16 bytes depending on address family)
            match geo_peer.peer.peer_ip {
                std::net::IpAddr::V4(ipv4) => {
                    buf.put_u32(ipv4.into());
                }
                std::net::IpAddr::V6(ipv6) => {
                    buf.extend_from_slice(&ipv6.octets());
                }
            }

            // Encode peer AS number (2 or 4 bytes depending on AS size)
            if geo_peer
                .peer
                .peer_type
                .contains(crate::models::PeerType::AS_SIZE_32BIT)
            {
                buf.put_u32(u32::from(geo_peer.peer.peer_asn));
            } else {
                buf.put_u16(u16::from(geo_peer.peer.peer_asn));
            }

            // Encode peer coordinates (4 bytes each, 32-bit float)
            buf.put_f32(geo_peer.peer_latitude);
            buf.put_f32(geo_peer.peer_longitude);
        }

        buf.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::BufMut;
    use bytes::BytesMut;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::str::FromStr;

    #[test]
    fn test_parse_geo_peer_table() {
        let mut data = BytesMut::new();

        // Collector BGP ID
        data.put_u32(0x0A000001); // 10.0.0.1

        // View name length and name
        let view_name = "test-view";
        data.put_u16(view_name.len() as u16);
        data.extend_from_slice(view_name.as_bytes());

        // Collector coordinates (London: 51.5074, -0.1278)
        data.put_f32(51.5074);
        data.put_f32(-0.1278);

        // Peer count
        data.put_u16(2);

        // First peer: IPv4, 2-byte AS
        data.put_u8(0x00); // Peer type: IPv4, 2-byte AS
        data.put_u32(0x01010101); // BGP ID: 1.1.1.1
        data.put_u32(0x02020202); // Peer IP: 2.2.2.2
        data.put_u16(65001); // AS number
        data.put_f32(40.7128); // New York latitude
        data.put_f32(-74.0060); // New York longitude

        // Second peer: IPv6, 4-byte AS
        data.put_u8(0x03); // Peer type: IPv6, 4-byte AS
        data.put_u32(0x03030303); // BGP ID: 3.3.3.3
                                  // IPv6 address: 2001:db8::1
        data.extend_from_slice(&[
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ]);
        data.put_u32(65002); // AS number
        data.put_f32(f32::NAN); // Private latitude
        data.put_f32(f32::NAN); // Private longitude

        let mut bytes = data.freeze();
        let result = parse_geo_peer_table(&mut bytes).unwrap();

        // Check collector info
        assert_eq!(
            result.collector_bgp_id,
            Ipv4Addr::from_str("10.0.0.1").unwrap()
        );
        assert_eq!(result.view_name, "test-view");
        assert_eq!(result.collector_latitude, 51.5074);
        assert_eq!(result.collector_longitude, -0.1278);

        // Check peer count
        assert_eq!(result.geo_peers.len(), 2);

        // Check first peer
        let peer1 = &result.geo_peers[0];
        assert_eq!(
            peer1.peer.peer_bgp_id,
            Ipv4Addr::from_str("1.1.1.1").unwrap()
        );
        assert_eq!(
            peer1.peer.peer_ip,
            IpAddr::V4(Ipv4Addr::from_str("2.2.2.2").unwrap())
        );
        assert_eq!(peer1.peer.peer_asn, Asn::new_16bit(65001));
        assert!(!peer1.peer.peer_type.contains(PeerType::ADDRESS_FAMILY_IPV6));
        assert!(!peer1.peer.peer_type.contains(PeerType::AS_SIZE_32BIT));
        assert_eq!(peer1.peer_latitude, 40.7128);
        assert_eq!(peer1.peer_longitude, -74.0060);

        // Check second peer
        let peer2 = &result.geo_peers[1];
        assert_eq!(
            peer2.peer.peer_bgp_id,
            Ipv4Addr::from_str("3.3.3.3").unwrap()
        );
        assert_eq!(
            peer2.peer.peer_ip,
            IpAddr::V6(Ipv6Addr::from_str("2001:db8::1").unwrap())
        );
        assert_eq!(peer2.peer.peer_asn, Asn::new_32bit(65002));
        assert!(peer2.peer.peer_type.contains(PeerType::ADDRESS_FAMILY_IPV6));
        assert!(peer2.peer.peer_type.contains(PeerType::AS_SIZE_32BIT));
        assert!(peer2.peer_latitude.is_nan());
        assert!(peer2.peer_longitude.is_nan());
    }

    #[test]
    fn test_parse_geo_peer_table_private_collector() {
        let mut data = BytesMut::new();

        // Collector BGP ID
        data.put_u32(0x0A000001); // 10.0.0.1

        // View name length and name
        let view_name = "private-view";
        data.put_u16(view_name.len() as u16);
        data.extend_from_slice(view_name.as_bytes());

        // Private collector coordinates (NaN)
        data.put_f32(f32::NAN);
        data.put_f32(f32::NAN);

        // No peers
        data.put_u16(0);

        let mut bytes = data.freeze();
        let result = parse_geo_peer_table(&mut bytes).unwrap();

        assert!(result.collector_latitude.is_nan());
        assert!(result.collector_longitude.is_nan());
        assert_eq!(result.geo_peers.len(), 0);
    }

    #[test]
    fn test_geo_peer_table_round_trip() {
        let collector_bgp_id = Ipv4Addr::from_str("192.168.1.1").unwrap();
        let mut original_table = GeoPeerTable::new(
            collector_bgp_id,
            "round-trip-test".to_string(),
            37.7749,   // San Francisco latitude
            -122.4194, // San Francisco longitude
        );

        // Add peers with different configurations
        let peer1 = Peer::new(
            Ipv4Addr::from_str("203.0.113.1").unwrap(),
            Ipv4Addr::from_str("203.0.113.2").unwrap().into(),
            Asn::new_16bit(64512),
        );
        let geo_peer1 = GeoPeer::new(peer1, 35.6762, 139.6503); // Tokyo
        original_table.add_geo_peer(geo_peer1);

        let peer2 = Peer::new(
            Ipv4Addr::from_str("198.51.100.1").unwrap(),
            std::net::Ipv6Addr::from_str("2001:db8:85a3::8a2e:370:7334")
                .unwrap()
                .into(),
            Asn::new_32bit(4200000000),
        );
        let geo_peer2 = GeoPeer::new(peer2, -33.8688, 151.2093); // Sydney
        original_table.add_geo_peer(geo_peer2);

        // Encode and then parse back
        let encoded = original_table.encode();
        let mut encoded_bytes = encoded;
        let parsed_table = parse_geo_peer_table(&mut encoded_bytes).unwrap();

        // Verify all fields match
        assert_eq!(
            parsed_table.collector_bgp_id,
            original_table.collector_bgp_id
        );
        assert_eq!(parsed_table.view_name, original_table.view_name);
        assert_eq!(
            parsed_table.collector_latitude,
            original_table.collector_latitude
        );
        assert_eq!(
            parsed_table.collector_longitude,
            original_table.collector_longitude
        );
        assert_eq!(parsed_table.geo_peers.len(), original_table.geo_peers.len());

        // Check first peer
        let parsed_peer1 = &parsed_table.geo_peers[0];
        let original_peer1 = &original_table.geo_peers[0];
        assert_eq!(
            parsed_peer1.peer.peer_bgp_id,
            original_peer1.peer.peer_bgp_id
        );
        assert_eq!(parsed_peer1.peer.peer_ip, original_peer1.peer.peer_ip);
        assert_eq!(parsed_peer1.peer.peer_asn, original_peer1.peer.peer_asn);
        assert_eq!(parsed_peer1.peer.peer_type, original_peer1.peer.peer_type);
        assert_eq!(parsed_peer1.peer_latitude, original_peer1.peer_latitude);
        assert_eq!(parsed_peer1.peer_longitude, original_peer1.peer_longitude);

        // Check second peer
        let parsed_peer2 = &parsed_table.geo_peers[1];
        let original_peer2 = &original_table.geo_peers[1];
        assert_eq!(
            parsed_peer2.peer.peer_bgp_id,
            original_peer2.peer.peer_bgp_id
        );
        assert_eq!(parsed_peer2.peer.peer_ip, original_peer2.peer.peer_ip);
        assert_eq!(parsed_peer2.peer.peer_asn, original_peer2.peer.peer_asn);
        assert_eq!(parsed_peer2.peer.peer_type, original_peer2.peer.peer_type);
        assert_eq!(parsed_peer2.peer_latitude, original_peer2.peer_latitude);
        assert_eq!(parsed_peer2.peer_longitude, original_peer2.peer_longitude);

        // Test overall equality
        assert_eq!(parsed_table, original_table);
    }

    #[test]
    fn test_geo_peer_table_encoding() {
        let collector_bgp_id = Ipv4Addr::from_str("10.0.0.1").unwrap();
        let mut geo_table = GeoPeerTable::new(
            collector_bgp_id,
            "test-view".to_string(),
            51.5074, // London latitude
            -0.1278, // London longitude
        );

        // Add a peer with IPv4 address and 2-byte AS
        let peer1 = Peer::new(
            Ipv4Addr::from_str("1.1.1.1").unwrap(),
            Ipv4Addr::from_str("2.2.2.2").unwrap().into(),
            Asn::new_16bit(65001),
        );
        let geo_peer1 = GeoPeer::new(peer1, 40.7128, -74.0060); // New York
        geo_table.add_geo_peer(geo_peer1);

        // Add a peer with IPv6 address and 4-byte AS
        let peer2 = Peer::new(
            Ipv4Addr::from_str("3.3.3.3").unwrap(),
            std::net::Ipv6Addr::from_str("2001:db8::1").unwrap().into(),
            Asn::new_32bit(65002),
        );
        let geo_peer2 = GeoPeer::new(peer2, f32::NAN, f32::NAN); // Private coordinates
        geo_table.add_geo_peer(geo_peer2);

        // Encode the geo table
        let encoded = geo_table.encode();

        // Create expected bytes manually for comparison
        let mut expected = BytesMut::new();

        // Collector BGP ID
        expected.put_u32(0x0A000001); // 10.0.0.1

        // View name length and name
        let view_name = "test-view";
        expected.put_u16(view_name.len() as u16);
        expected.extend_from_slice(view_name.as_bytes());

        // Collector coordinates
        expected.put_f32(51.5074);
        expected.put_f32(-0.1278);

        // Peer count
        expected.put_u16(2);

        // First peer: IPv4, 2-byte AS
        expected.put_u8(0x00); // Peer type: IPv4, 2-byte AS
        expected.put_u32(0x01010101); // BGP ID: 1.1.1.1
        expected.put_u32(0x02020202); // Peer IP: 2.2.2.2
        expected.put_u16(65001); // AS number
        expected.put_f32(40.7128); // New York latitude
        expected.put_f32(-74.0060); // New York longitude

        // Second peer: IPv6, 4-byte AS
        expected.put_u8(0x03); // Peer type: IPv6, 4-byte AS
        expected.put_u32(0x03030303); // BGP ID: 3.3.3.3
        expected.extend_from_slice(&[
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ]); // IPv6: 2001:db8::1
        expected.put_u32(65002); // AS number
        expected.put_f32(f32::NAN); // Private latitude
        expected.put_f32(f32::NAN); // Private longitude

        let expected_bytes = expected.freeze();

        // Compare the encoded bytes with expected
        assert_eq!(encoded.len(), expected_bytes.len());
        assert_eq!(encoded, expected_bytes);
    }
}
