use crate::models::{Afi, AsnLength, Peer, PeerIndexTable, PeerType};
use crate::parser::ReadUtils;
use crate::ParserError;
use bytes::{BufMut, Bytes, BytesMut};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};

/// Parses a byte slice into a [PeerIndexTable].
///
/// RFC: https://www.rfc-editor.org/rfc/rfc6396#section-4.3.1
///
/// # Arguments
///
/// * `data` - The byte slice to parse.
///
/// # Returns
///
/// - `Ok(PeerIndexTable)` if the parsing is successful.
/// - `Err(ParserError)` if an error occurs during parsing.
pub fn parse_peer_index_table(data: &mut Bytes) -> Result<PeerIndexTable, ParserError> {
    let collector_bgp_id = Ipv4Addr::from(data.read_u32()?);
    // read and ignore view name
    let view_name_length = data.read_u16()?;
    let view_name =
        String::from_utf8(data.read_n_bytes(view_name_length as usize)?).unwrap_or("".to_string());

    let peer_count = data.read_u16()?;
    let mut peers = vec![];
    for _index in 0..peer_count {
        let peer_type = PeerType::from_bits_retain(data.read_u8()?);
        let afi = match peer_type.contains(PeerType::ADDRESS_FAMILY_IPV6) {
            true => Afi::Ipv6,
            false => Afi::Ipv4,
        };
        let asn_len = match peer_type.contains(PeerType::AS_SIZE_32BIT) {
            true => AsnLength::Bits32,
            false => AsnLength::Bits16,
        };

        let peer_bgp_id = Ipv4Addr::from(data.read_u32()?);
        let peer_ip: IpAddr = data.read_address(&afi)?;
        let peer_asn = data.read_asn(asn_len)?;
        peers.push(Peer {
            peer_type,
            peer_bgp_id,
            peer_ip,
            peer_asn,
        })
    }

    let mut id_peer_map = HashMap::new();
    let mut peer_ip_id_map = HashMap::new();

    for (id, p) in peers.into_iter().enumerate() {
        id_peer_map.insert(id as u16, p);
        peer_ip_id_map.insert(p.peer_ip, id as u16);
    }

    Ok(PeerIndexTable {
        collector_bgp_id,
        view_name,
        id_peer_map,
        peer_ip_id_map,
    })
}

impl PeerIndexTable {
    /// Add peer to peer index table and return peer id
    pub fn add_peer(&mut self, peer: Peer) -> u16 {
        match self.peer_ip_id_map.get(&peer.peer_ip) {
            Some(id) => *id,
            None => {
                let peer_id = self.peer_ip_id_map.len() as u16;
                self.peer_ip_id_map.insert(peer.peer_ip, peer_id);
                self.id_peer_map.insert(peer_id, peer);
                peer_id
            }
        }
    }

    /// Returns the peer associated with the given peer ID.
    ///
    /// # Arguments
    ///
    /// * `peer_id` - A reference to the peer ID.
    ///
    /// # Returns
    ///
    /// An `Option` containing a reference to the [Peer] if found, otherwise `None`.
    pub fn get_peer_by_id(&self, peer_id: &u16) -> Option<&Peer> {
        self.id_peer_map.get(peer_id)
    }

    /// Returns the peer ID associated with the given IP address.
    ///
    /// # Arguments
    ///
    /// * `peer_ip` - The IP address of the peer.
    ///
    /// # Returns
    ///
    /// An optional `u16` representing the peer ID. Returns `None` if the IP address is not found.
    ///
    /// # Examples
    ///
    /// ```
    /// use std::net::IpAddr;
    /// use std::str::FromStr;
    /// use bgpkit_parser::models::PeerIndexTable;
    ///
    /// let index_table = PeerIndexTable::default();
    /// let peer_ip = IpAddr::from_str("127.0.0.1").unwrap();
    /// let peer_id = index_table.get_peer_id_by_addr(&peer_ip);
    /// ```
    pub fn get_peer_id_by_addr(&self, peer_ip: &IpAddr) -> Option<u16> {
        self.peer_ip_id_map.get(peer_ip).copied()
    }

    /// Encode the data in the struct into a byte array.
    ///
    /// # Returns
    ///
    /// A `Bytes` object containing the encoded data.
    ///
    /// # Example
    ///
    /// ```
    /// use std::collections::HashMap;
    /// use std::net::Ipv4Addr;
    /// use bgpkit_parser::models::PeerIndexTable;
    ///
    /// let data = PeerIndexTable {
    ///     collector_bgp_id: Ipv4Addr::from(1234),
    ///     view_name: String::from("example"),
    ///     id_peer_map: HashMap::new(),
    ///     peer_ip_id_map: Default::default(),
    /// };
    ///
    /// let encoded = data.encode();
    /// ```
    pub fn encode(&self) -> Bytes {
        let mut buf = BytesMut::new();

        // Encode collector_bgp_id
        buf.put_u32(self.collector_bgp_id.into());

        // Encode view_name_length
        let view_name_bytes = self.view_name.as_bytes();
        buf.put_u16(view_name_bytes.len() as u16);

        // Encode view_name
        buf.extend(view_name_bytes);

        // Encode peer_count
        let peer_count = self.id_peer_map.len() as u16;
        buf.put_u16(peer_count);

        // Encode peers
        let mut peer_ids: Vec<_> = self.id_peer_map.keys().collect();
        peer_ids.sort();
        for id in peer_ids {
            let peer = self.id_peer_map.get(id).unwrap();
            // Encode PeerType
            buf.put_u8(peer.peer_type.bits());

            // Encode peer_bgp_id
            buf.put_u32(peer.peer_bgp_id.into());

            // Encode peer_ip
            match peer.peer_ip {
                IpAddr::V4(ipv4) => {
                    buf.put_slice(&ipv4.octets());
                }
                IpAddr::V6(ipv6) => {
                    buf.put_slice(&ipv6.octets());
                }
            };

            // Encode peer_asn
            match peer.peer_type.contains(PeerType::AS_SIZE_32BIT) {
                true => buf.put_u32(peer.peer_asn.to_u32()),
                false => buf.put_u16(peer.peer_asn.to_u32() as u16),
            };
        }

        // Return Bytes
        buf.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Asn;
    use std::str::FromStr;

    #[test]
    fn test_peer_index_table_encode() {
        let mut index_table = PeerIndexTable {
            collector_bgp_id: Ipv4Addr::from(1234),
            view_name: String::from("example"),
            id_peer_map: HashMap::new(),
            peer_ip_id_map: Default::default(),
        };

        index_table.add_peer(Peer::new(
            Ipv4Addr::from(1234),
            IpAddr::from_str("192.168.1.1").unwrap(),
            Asn::new_32bit(1234),
        ));
        index_table.add_peer(Peer::new(
            Ipv4Addr::from(12345),
            IpAddr::from_str("192.168.1.2").unwrap(),
            Asn::new_32bit(12345),
        ));

        let encoded = index_table.encode();
        let parsed_index_table = parse_peer_index_table(&mut encoded.clone()).unwrap();
        assert_eq!(index_table, parsed_index_table);
    }

    #[test]
    fn test_get_peer_by_id() {
        let mut index_table = PeerIndexTable {
            collector_bgp_id: Ipv4Addr::from(1234),
            view_name: String::from("example"),
            id_peer_map: HashMap::new(),
            peer_ip_id_map: Default::default(),
        };

        let peer1 = Peer::new(
            Ipv4Addr::from(1234),
            IpAddr::from_str("10.0.0.1").unwrap(),
            Asn::new_32bit(1234),
        );
        let peer2 = Peer::new(
            Ipv4Addr::from(12345),
            IpAddr::from_str("10.0.0.2").unwrap(),
            Asn::new_32bit(12345),
        );

        let peer1_id = index_table.add_peer(peer1);
        let peer2_id = index_table.add_peer(peer2);

        assert_eq!(
            index_table.get_peer_by_id(&peer1_id),
            Some(&Peer::new(
                Ipv4Addr::from(1234),
                IpAddr::from_str("10.0.0.1").unwrap(),
                Asn::new_32bit(1234),
            ))
        );
        assert_eq!(
            index_table.get_peer_by_id(&peer2_id),
            Some(&Peer::new(
                Ipv4Addr::from(12345),
                IpAddr::from_str("10.0.0.2").unwrap(),
                Asn::new_32bit(12345),
            ))
        );
    }
}
