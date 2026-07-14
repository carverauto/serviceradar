//! MRT Encoder module
//!
//! `mrt_encoder` module handles serializing BGP/MRT messages back to MRT binary files. The main
//! difficulty part of this process is the handling of TableDumpV2 RIB dumps, which requires
//! reconstructing the peer index table before encoding all other contents.

use crate::models::{
    Attributes, BgpElem, CommonHeader, EntryType, MrtMessage, NetworkPrefix, Peer, PeerIndexTable,
    RibAfiEntries, RibEntry, TableDumpV2Message, TableDumpV2Type,
};
use crate::utils::convert_timestamp;
use bytes::{Bytes, BytesMut};
use ipnet::IpNet;
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr};

#[derive(Default)]
pub struct MrtRibEncoder {
    index_table: PeerIndexTable,

    per_prefix_entries_map: HashMap<IpNet, HashMap<u16, RibEntry>>,

    timestamp: f64,
}

impl MrtRibEncoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        self.index_table = PeerIndexTable::default();
        self.per_prefix_entries_map = HashMap::default();
        self.timestamp = 0.0;
    }

    /// Processes a BgpElem and updates the internal data structures.
    ///
    /// # Arguments
    ///
    /// * `elem` - A reference to a BgpElem that contains the information to be processed.
    pub fn process_elem(&mut self, elem: &BgpElem) {
        if self.timestamp == 0.0 {
            self.timestamp = elem.timestamp;
        }
        let bgp_identifier = match elem.peer_ip {
            IpAddr::V4(ip) => ip,
            IpAddr::V6(_ip) => Ipv4Addr::from(0),
        };
        let peer = Peer::new(bgp_identifier, elem.peer_ip, elem.peer_asn);
        let peer_index = self.index_table.add_peer(peer);
        let path_id = elem.prefix.path_id;
        let prefix = elem.prefix.prefix;

        let entries_map = self.per_prefix_entries_map.entry(prefix).or_default();
        let entry = RibEntry {
            peer_index,
            path_id,
            originated_time: elem.timestamp as u32,
            attributes: Attributes::from(elem),
        };
        entries_map.insert(peer_index, entry);
    }

    /// Export the data stored in the struct to a byte array.
    ///
    /// The function first encodes the peer-index-table data into a `MrtMessage` and appends it to the `BytesMut` object.
    /// Then, for each prefix in the `per_prefix_entries_map`, it creates a `RibAfiEntries` object and encodes it as a `MrtMessage`.
    /// The resulting `BytesMut` object is then converted to an immutable `Bytes` object using `freeze()` and returned.
    ///
    /// # Return
    /// Returns a `Bytes` object containing the exported data as a byte array.
    pub fn export_bytes(&mut self) -> Bytes {
        let mut bytes = BytesMut::new();

        // encode peer-index-table
        let mrt_message = MrtMessage::TableDumpV2Message(TableDumpV2Message::PeerIndexTable(
            self.index_table.clone(),
        ));
        let (seconds, _microseconds) = convert_timestamp(self.timestamp);
        let subtype = TableDumpV2Type::PeerIndexTable as u16;
        let data_bytes = mrt_message.encode(subtype);
        let header = CommonHeader {
            timestamp: seconds,
            microsecond_timestamp: None,
            entry_type: EntryType::TABLE_DUMP_V2,
            entry_subtype: subtype,
            length: data_bytes.len() as u32,
        };
        let header_bytes = header.encode();
        bytes.extend(header_bytes);
        bytes.extend(data_bytes);

        // encode each RibAfiEntries
        for (entry_count, (prefix, entries_map)) in self.per_prefix_entries_map.iter().enumerate() {
            let rib_type = match prefix.addr().is_ipv6() {
                true => TableDumpV2Type::RibIpv6Unicast,
                false => TableDumpV2Type::RibIpv4Unicast,
            };

            let mut prefix_rib_entry = RibAfiEntries {
                rib_type,
                sequence_number: entry_count as u32,
                prefix: NetworkPrefix::new(*prefix, None),
                rib_entries: vec![],
            };
            for entry in entries_map.values() {
                prefix_rib_entry.rib_entries.push(entry.clone());
            }

            let mrt_message =
                MrtMessage::TableDumpV2Message(TableDumpV2Message::RibAfi(prefix_rib_entry));

            let (seconds, _microseconds) = convert_timestamp(self.timestamp);
            let subtype = rib_type as u16;
            let data_bytes = mrt_message.encode(subtype);
            let header_bytes = CommonHeader {
                timestamp: seconds,
                microsecond_timestamp: None,
                entry_type: EntryType::TABLE_DUMP_V2,
                entry_subtype: subtype,
                length: data_bytes.len() as u32,
            }
            .encode();
            bytes.extend(header_bytes);
            bytes.extend(data_bytes);
        }

        self.reset();

        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::Asn;
    use crate::parse_mrt_record;
    use bytes::Buf;
    use std::io::Cursor;

    #[test]
    fn test_encoding_rib() {
        let mut encoder = MrtRibEncoder::new();
        let mut elem = BgpElem {
            peer_ip: IpAddr::V4("10.0.0.1".parse().unwrap()),
            peer_asn: Asn::from(65000),
            ..Default::default()
        };
        elem.prefix.prefix = "10.250.0.0/24".parse().unwrap();
        encoder.process_elem(&elem);
        elem.prefix.prefix = "10.251.0.0/24".parse().unwrap();
        encoder.process_elem(&elem);
        let bytes = encoder.export_bytes();

        let mut cursor = Cursor::new(bytes.clone());
        while cursor.has_remaining() {
            let _parsed = parse_mrt_record(&mut cursor).unwrap();
        }

        // v6
        let mut encoder = MrtRibEncoder::new();
        let mut elem = BgpElem {
            peer_ip: IpAddr::V6("::1".parse().unwrap()),
            peer_asn: Asn::from(65000),
            ..Default::default()
        };
        // ipv6 prefix
        elem.prefix.prefix = "2001:db8::/32".parse().unwrap();
        encoder.process_elem(&elem);
        let bytes = encoder.export_bytes();

        let mut cursor = Cursor::new(bytes.clone());
        while cursor.has_remaining() {
            let _parsed = parse_mrt_record(&mut cursor).unwrap();
        }
    }
}
