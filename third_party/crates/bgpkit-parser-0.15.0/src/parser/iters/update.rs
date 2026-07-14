/*!
Update message iterator implementation.

This module provides iterators that yield BGP announcement data from MRT files,
supporting both BGP4MP UPDATE messages and RIB dump entries.

## Overview

The iterators in this module provide a middle ground between `MrtRecord` and `BgpElem`:
- More focused than `MrtRecord` as they only yield BGP announcements
- More efficient than `BgpElem` as they avoid duplicating attributes for each prefix

## Message Types

### BGP4MP Updates (from UPDATES files)
- One message contains multiple prefixes sharing the SAME attributes
- Efficient when you need to process updates without per-prefix attribute cloning

### RIB Entries (from RIB dump files)
- One record contains ONE prefix with multiple RIB entries (one per peer)
- Each peer has its own attributes for the same prefix

## Usage

```no_run
use bgpkit_parser::BgpkitParser;

let parser = BgpkitParser::new("updates.mrt").unwrap();
for announcement in parser.into_update_iter() {
    match announcement {
        bgpkit_parser::MrtUpdate::Bgp4MpUpdate(update) => {
            println!("BGP UPDATE from peer {}", update.peer_ip);
        }
        bgpkit_parser::MrtUpdate::TableDumpV2Entry(entry) => {
            println!("RIB entry for prefix {}", entry.prefix);
        }
        bgpkit_parser::MrtUpdate::TableDumpMessage(msg) => {
            println!("Legacy table dump for prefix {}", msg.prefix);
        }
    }
}
```
*/
use crate::error::ParserError;
use crate::models::*;
use crate::parser::BgpkitParser;
use crate::Elementor;
use log::{error, warn};
use std::io::Read;
use std::net::IpAddr;

/// A BGP4MP UPDATE message with associated metadata.
///
/// This struct wraps a `BgpUpdateMessage` with the peer information and timestamp
/// from the MRT record. It's more efficient than `BgpElem` when a single UPDATE
/// contains multiple prefixes, as the attributes are not duplicated.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Bgp4MpUpdate {
    /// The timestamp of the MRT record in floating-point format (seconds since epoch).
    pub timestamp: f64,
    /// The IP address of the BGP peer that sent this update.
    pub peer_ip: IpAddr,
    /// The ASN of the BGP peer that sent this update.
    pub peer_asn: Asn,
    /// The BGP UPDATE message containing announcements, withdrawals, and attributes.
    pub message: BgpUpdateMessage,
}

/// A TableDumpV2 RIB entry with associated metadata.
///
/// This struct represents a single prefix with all its RIB entries from different peers.
/// Each RIB entry contains the peer information and attributes for that prefix.
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TableDumpV2Entry {
    /// The timestamp from the MRT header.
    pub timestamp: f64,
    /// The RIB subtype (IPv4 Unicast, IPv6 Unicast, etc.)
    pub rib_type: TableDumpV2Type,
    /// The sequence number of this RIB entry.
    pub sequence_number: u32,
    /// The network prefix for this RIB entry.
    pub prefix: NetworkPrefix,
    /// The RIB entries for this prefix, one per peer.
    /// Each entry contains peer_index, originated_time, and attributes.
    pub rib_entries: Vec<RibEntry>,
}

/// Unified enum representing BGP announcements from different MRT message types.
///
/// This enum provides a common interface for processing BGP data from:
/// - BGP4MP UPDATE messages (real-time updates)
/// - TableDumpV2 RIB entries (routing table snapshots)
/// - Legacy TableDump messages
#[derive(Debug, Clone, PartialEq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum MrtUpdate {
    /// A BGP4MP UPDATE message from an UPDATES file.
    Bgp4MpUpdate(Bgp4MpUpdate),
    /// A TableDumpV2 RIB entry from a RIB dump file.
    TableDumpV2Entry(TableDumpV2Entry),
    /// A legacy TableDump (v1) message.
    TableDumpMessage(TableDumpMessage),
}

impl MrtUpdate {
    /// Returns the timestamp of this update/entry.
    pub fn timestamp(&self) -> f64 {
        match self {
            MrtUpdate::Bgp4MpUpdate(u) => u.timestamp,
            MrtUpdate::TableDumpV2Entry(e) => e.timestamp,
            MrtUpdate::TableDumpMessage(m) => m.originated_time as f64,
        }
    }
}

/// Iterator over BGP announcements from MRT data.
///
/// This iterator yields `MrtUpdate` items from both UPDATES files (BGP4MP messages)
/// and RIB dump files (TableDump/TableDumpV2 messages).
///
/// Unlike `ElemIterator`, this iterator does not expand messages into individual
/// `BgpElem`s, making it more efficient for use cases that need to process
/// the raw message structures.
pub struct UpdateIterator<R> {
    parser: BgpkitParser<R>,
    elementor: Elementor,
}

impl<R> UpdateIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        UpdateIterator {
            parser,
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for UpdateIterator<R> {
    type Item = MrtUpdate;

    fn next(&mut self) -> Option<MrtUpdate> {
        loop {
            let record = match self.parser.next_record() {
                Ok(record) => record,
                Err(e) => match e.error {
                    ParserError::TruncatedMsg(err_str) | ParserError::Unsupported(err_str) => {
                        if self.parser.options.show_warnings {
                            warn!("parser warn: {}", err_str);
                        }
                        if self.parser.core_dump {
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                        }
                        continue;
                    }
                    ParserError::ParseError(err_str) => {
                        error!("parser error: {}", err_str);
                        if self.parser.core_dump {
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                            return None;
                        }
                        continue;
                    }
                    ParserError::EofExpected => return None,
                    ParserError::IoError(err) | ParserError::EofError(err) => {
                        error!("{:?}", err);
                        if self.parser.core_dump {
                            if let Some(bytes) = e.bytes {
                                std::fs::write("mrt_core_dump", bytes)
                                    .expect("Unable to write to mrt_core_dump");
                            }
                        }
                        return None;
                    }
                    #[cfg(feature = "oneio")]
                    ParserError::OneIoError(_) => return None,
                    ParserError::FilterError(_) => return None,
                },
            };

            let t = record.common_header.timestamp;
            let timestamp: f64 = if let Some(micro) = &record.common_header.microsecond_timestamp {
                let m = (*micro as f64) / 1_000_000.0;
                t as f64 + m
            } else {
                f64::from(t)
            };

            match record.message {
                MrtMessage::Bgp4Mp(Bgp4MpEnum::Message(msg)) => {
                    if let BgpMessage::Update(update) = msg.bgp_message {
                        return Some(MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
                            timestamp,
                            peer_ip: msg.peer_ip,
                            peer_asn: msg.peer_asn,
                            message: update,
                        }));
                    }
                    // Not an UPDATE message (OPEN, NOTIFICATION, KEEPALIVE), continue
                    continue;
                }
                MrtMessage::Bgp4Mp(Bgp4MpEnum::StateChange(_)) => {
                    // State change messages don't contain announcement data
                    continue;
                }
                MrtMessage::TableDumpV2Message(msg) => {
                    match msg {
                        TableDumpV2Message::PeerIndexTable(p) => {
                            // Store peer table for later use and continue
                            self.elementor.peer_table = Some(p);
                            continue;
                        }
                        TableDumpV2Message::RibAfi(entries) => {
                            return Some(MrtUpdate::TableDumpV2Entry(TableDumpV2Entry {
                                timestamp,
                                rib_type: entries.rib_type,
                                sequence_number: entries.sequence_number,
                                prefix: entries.prefix,
                                rib_entries: entries.rib_entries,
                            }));
                        }
                        TableDumpV2Message::RibGeneric(_) => {
                            // RibGeneric is not commonly used, skip for now
                            continue;
                        }
                        TableDumpV2Message::GeoPeerTable(_) => {
                            // GeoPeerTable doesn't contain route data
                            continue;
                        }
                    }
                }
                MrtMessage::TableDumpMessage(msg) => {
                    return Some(MrtUpdate::TableDumpMessage(msg));
                }
            }
        }
    }
}

/// Fallible iterator over BGP announcements that returns parsing errors.
///
/// Unlike the default `UpdateIterator`, this iterator returns `Result<MrtUpdate, ParserErrorWithBytes>`
/// allowing users to handle parsing errors explicitly instead of having them logged and skipped.
pub struct FallibleUpdateIterator<R> {
    parser: BgpkitParser<R>,
    elementor: Elementor,
}

impl<R> FallibleUpdateIterator<R> {
    pub(crate) fn new(parser: BgpkitParser<R>) -> Self {
        FallibleUpdateIterator {
            parser,
            elementor: Elementor::new(),
        }
    }
}

impl<R: Read> Iterator for FallibleUpdateIterator<R> {
    type Item = Result<MrtUpdate, crate::error::ParserErrorWithBytes>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match self.parser.next_record() {
                Ok(record) => {
                    let t = record.common_header.timestamp;
                    let timestamp: f64 =
                        if let Some(micro) = &record.common_header.microsecond_timestamp {
                            let m = (*micro as f64) / 1_000_000.0;
                            t as f64 + m
                        } else {
                            f64::from(t)
                        };

                    match record.message {
                        MrtMessage::Bgp4Mp(Bgp4MpEnum::Message(msg)) => {
                            if let BgpMessage::Update(update) = msg.bgp_message {
                                return Some(Ok(MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
                                    timestamp,
                                    peer_ip: msg.peer_ip,
                                    peer_asn: msg.peer_asn,
                                    message: update,
                                })));
                            }
                            continue;
                        }
                        MrtMessage::Bgp4Mp(Bgp4MpEnum::StateChange(_)) => {
                            continue;
                        }
                        MrtMessage::TableDumpV2Message(msg) => match msg {
                            TableDumpV2Message::PeerIndexTable(p) => {
                                self.elementor.peer_table = Some(p);
                                continue;
                            }
                            TableDumpV2Message::RibAfi(entries) => {
                                return Some(Ok(MrtUpdate::TableDumpV2Entry(TableDumpV2Entry {
                                    timestamp,
                                    rib_type: entries.rib_type,
                                    sequence_number: entries.sequence_number,
                                    prefix: entries.prefix,
                                    rib_entries: entries.rib_entries,
                                })));
                            }
                            TableDumpV2Message::RibGeneric(_) => {
                                continue;
                            }
                            TableDumpV2Message::GeoPeerTable(_) => {
                                continue;
                            }
                        },
                        MrtMessage::TableDumpMessage(msg) => {
                            return Some(Ok(MrtUpdate::TableDumpMessage(msg)));
                        }
                    }
                }
                Err(e) if matches!(e.error, ParserError::EofExpected) => {
                    return None;
                }
                Err(e) => {
                    return Some(Err(e));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_bgp4mp_update_struct() {
        let update = Bgp4MpUpdate {
            timestamp: 1234567890.123456,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        };

        assert_eq!(update.timestamp, 1234567890.123456);
        assert_eq!(update.peer_ip.to_string(), "192.0.2.1");
        assert_eq!(update.peer_asn, Asn::new_32bit(65000));
    }

    #[test]
    fn test_table_dump_v2_entry_struct() {
        let entry = TableDumpV2Entry {
            timestamp: 1234567890.0,
            rib_type: TableDumpV2Type::RibIpv4Unicast,
            sequence_number: 42,
            prefix: "10.0.0.0/8".parse().unwrap(),
            rib_entries: vec![],
        };

        assert_eq!(entry.timestamp, 1234567890.0);
        assert_eq!(entry.rib_type, TableDumpV2Type::RibIpv4Unicast);
        assert_eq!(entry.sequence_number, 42);
        assert_eq!(entry.prefix.to_string(), "10.0.0.0/8");
        assert!(entry.rib_entries.is_empty());
    }

    #[test]
    fn test_mrt_update_timestamp() {
        // Test Bgp4MpUpdate variant
        let bgp4mp = MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
            timestamp: 1234567890.5,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        });
        assert_eq!(bgp4mp.timestamp(), 1234567890.5);

        // Test TableDumpV2Entry variant
        let table_dump_v2 = MrtUpdate::TableDumpV2Entry(TableDumpV2Entry {
            timestamp: 1234567891.5,
            rib_type: TableDumpV2Type::RibIpv4Unicast,
            sequence_number: 1,
            prefix: "10.0.0.0/8".parse().unwrap(),
            rib_entries: vec![],
        });
        assert_eq!(table_dump_v2.timestamp(), 1234567891.5);

        // Test TableDumpMessage variant
        let table_dump_v1 = MrtUpdate::TableDumpMessage(TableDumpMessage {
            view_number: 0,
            sequence_number: 1,
            prefix: "192.168.0.0/16".parse().unwrap(),
            status: 1,
            originated_time: 1234567892,
            peer_ip: "10.0.0.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65001),
            attributes: Attributes::default(),
        });
        assert_eq!(table_dump_v1.timestamp(), 1234567892.0);
    }

    #[test]
    fn test_update_iterator_empty() {
        let cursor = Cursor::new(vec![]);
        let parser = BgpkitParser::from_reader(cursor);
        let mut iter = UpdateIterator::new(parser);

        assert!(iter.next().is_none());
    }

    #[test]
    fn test_fallible_update_iterator_empty() {
        let cursor = Cursor::new(vec![]);
        let parser = BgpkitParser::from_reader(cursor);
        let mut iter = FallibleUpdateIterator::new(parser);

        assert!(iter.next().is_none());
    }

    #[test]
    fn test_bgp4mp_update_clone_and_debug() {
        let update = Bgp4MpUpdate {
            timestamp: 1234567890.123456,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        };

        // Test Clone
        let cloned = update.clone();
        assert_eq!(update, cloned);

        // Test Debug
        let debug_str = format!("{:?}", update);
        assert!(debug_str.contains("Bgp4MpUpdate"));
        assert!(debug_str.contains("192.0.2.1"));
    }

    #[test]
    fn test_table_dump_v2_entry_clone_and_debug() {
        let entry = TableDumpV2Entry {
            timestamp: 1234567890.0,
            rib_type: TableDumpV2Type::RibIpv4Unicast,
            sequence_number: 42,
            prefix: "10.0.0.0/8".parse().unwrap(),
            rib_entries: vec![],
        };

        // Test Clone
        let cloned = entry.clone();
        assert_eq!(entry, cloned);

        // Test Debug
        let debug_str = format!("{:?}", entry);
        assert!(debug_str.contains("TableDumpV2Entry"));
        assert!(debug_str.contains("10.0.0.0/8"));
    }

    #[test]
    fn test_mrt_update_clone_and_debug() {
        let update = MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
            timestamp: 1234567890.5,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        });

        // Test Clone
        let cloned = update.clone();
        assert_eq!(update, cloned);

        // Test Debug
        let debug_str = format!("{:?}", update);
        assert!(debug_str.contains("Bgp4MpUpdate"));
    }

    #[test]
    fn test_fallible_update_iterator_with_invalid_data() {
        // Create invalid MRT data that will trigger a parsing error
        let invalid_data = vec![
            0x00, 0x00, 0x00, 0x00, // timestamp
            0xFF, 0xFF, // invalid type
            0x00, 0x00, // subtype
            0x00, 0x00, 0x00, 0x04, // length
            0x00, 0x00, 0x00, 0x00, // dummy data
        ];

        let cursor = Cursor::new(invalid_data);
        let parser = BgpkitParser::from_reader(cursor);
        let mut iter = FallibleUpdateIterator::new(parser);

        // First item should be an error
        let result = iter.next();
        assert!(result.is_some());
        assert!(result.unwrap().is_err());
    }

    #[test]
    fn test_mrt_update_enum_variants() {
        // Test that all enum variants can be constructed and matched
        let updates: Vec<MrtUpdate> = vec![
            MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
                timestamp: 1.0,
                peer_ip: "192.0.2.1".parse().unwrap(),
                peer_asn: Asn::new_32bit(65000),
                message: BgpUpdateMessage::default(),
            }),
            MrtUpdate::TableDumpV2Entry(TableDumpV2Entry {
                timestamp: 2.0,
                rib_type: TableDumpV2Type::RibIpv6Unicast,
                sequence_number: 1,
                prefix: "2001:db8::/32".parse().unwrap(),
                rib_entries: vec![],
            }),
            MrtUpdate::TableDumpMessage(TableDumpMessage {
                view_number: 0,
                sequence_number: 1,
                prefix: "10.0.0.0/8".parse().unwrap(),
                status: 1,
                originated_time: 3,
                peer_ip: "10.0.0.1".parse().unwrap(),
                peer_asn: Asn::new_32bit(65001),
                attributes: Attributes::default(),
            }),
        ];

        for (i, update) in updates.iter().enumerate() {
            match update {
                MrtUpdate::Bgp4MpUpdate(_) => assert_eq!(i, 0),
                MrtUpdate::TableDumpV2Entry(_) => assert_eq!(i, 1),
                MrtUpdate::TableDumpMessage(_) => assert_eq!(i, 2),
            }
        }
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_bgp4mp_update_serde() {
        let update = Bgp4MpUpdate {
            timestamp: 1234567890.123456,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        };

        let serialized = serde_json::to_string(&update).unwrap();
        let deserialized: Bgp4MpUpdate = serde_json::from_str(&serialized).unwrap();
        assert_eq!(update, deserialized);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_table_dump_v2_entry_serde() {
        let entry = TableDumpV2Entry {
            timestamp: 1234567890.0,
            rib_type: TableDumpV2Type::RibIpv4Unicast,
            sequence_number: 42,
            prefix: "10.0.0.0/8".parse().unwrap(),
            rib_entries: vec![],
        };

        let serialized = serde_json::to_string(&entry).unwrap();
        let deserialized: TableDumpV2Entry = serde_json::from_str(&serialized).unwrap();
        assert_eq!(entry, deserialized);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_mrt_update_serde() {
        let update = MrtUpdate::Bgp4MpUpdate(Bgp4MpUpdate {
            timestamp: 1234567890.5,
            peer_ip: "192.0.2.1".parse().unwrap(),
            peer_asn: Asn::new_32bit(65000),
            message: BgpUpdateMessage::default(),
        });

        let serialized = serde_json::to_string(&update).unwrap();
        let deserialized: MrtUpdate = serde_json::from_str(&serialized).unwrap();
        assert_eq!(update, deserialized);
    }

    /// Test parsing real UPDATES file data
    #[test]
    fn test_update_iterator_with_updates_file() {
        let url = "https://spaces.bgpkit.org/parser/update-example";
        let parser = BgpkitParser::new(url).unwrap();

        let mut bgp4mp_count = 0;
        let mut total_announced = 0;
        let mut total_withdrawn = 0;

        for update in parser.into_update_iter() {
            match update {
                MrtUpdate::Bgp4MpUpdate(u) => {
                    bgp4mp_count += 1;
                    total_announced += u.message.announced_prefixes.len();
                    total_withdrawn += u.message.withdrawn_prefixes.len();
                    // Also count MP_REACH/MP_UNREACH prefixes
                    for attr in &u.message.attributes {
                        match attr {
                            AttributeValue::MpReachNlri(nlri) => {
                                total_announced += nlri.prefixes.len();
                            }
                            AttributeValue::MpUnreachNlri(nlri) => {
                                total_withdrawn += nlri.prefixes.len();
                            }
                            _ => {}
                        }
                    }
                }
                MrtUpdate::TableDumpV2Entry(_) => {
                    panic!("Should not see TableDumpV2Entry in UPDATES file");
                }
                MrtUpdate::TableDumpMessage(_) => {
                    panic!("Should not see TableDumpMessage in UPDATES file");
                }
            }
        }

        // Verify we got some data
        assert!(bgp4mp_count > 0, "Should have parsed some BGP4MP updates");
        assert!(
            total_announced + total_withdrawn > 0,
            "Should have some prefixes"
        );
    }

    /// Test parsing real RIB dump file data
    #[test]
    fn test_update_iterator_with_rib_file() {
        let url = "https://spaces.bgpkit.org/parser/rib-example-small.bz2";
        let parser = BgpkitParser::new(url).unwrap();

        let mut rib_entry_count = 0;
        let mut total_rib_entries = 0;

        for update in parser.into_update_iter().take(100) {
            match update {
                MrtUpdate::Bgp4MpUpdate(_) => {
                    panic!("Should not see Bgp4MpUpdate in RIB file");
                }
                MrtUpdate::TableDumpV2Entry(e) => {
                    rib_entry_count += 1;
                    total_rib_entries += e.rib_entries.len();
                    // Verify the entry has valid data
                    assert!(e.sequence_number > 0 || rib_entry_count == 1);
                }
                MrtUpdate::TableDumpMessage(_) => {
                    // Legacy format is also acceptable in RIB files
                }
            }
        }

        // Verify we got some data
        assert!(rib_entry_count > 0, "Should have parsed some RIB entries");
        assert!(
            total_rib_entries > 0,
            "Should have some RIB entries per prefix"
        );
    }

    /// Test fallible iterator with real data
    #[test]
    fn test_fallible_update_iterator_with_updates_file() {
        let url = "https://spaces.bgpkit.org/parser/update-example";
        let parser = BgpkitParser::new(url).unwrap();

        let mut success_count = 0;
        let mut error_count = 0;

        for result in parser.into_fallible_update_iter() {
            match result {
                Ok(_) => success_count += 1,
                Err(_) => error_count += 1,
            }
        }

        assert!(
            success_count > 0,
            "Should have parsed some updates successfully"
        );
        // The test file should be valid, so we expect no errors
        assert_eq!(
            error_count, 0,
            "Should have no parsing errors in valid file"
        );
    }

    /// Test that UpdateIterator and ElemIterator yield consistent prefix counts
    #[test]
    fn test_update_iter_vs_elem_iter_consistency() {
        let url = "https://spaces.bgpkit.org/parser/update-example";

        // Count prefixes using UpdateIterator
        let parser1 = BgpkitParser::new(url).unwrap();
        let mut update_iter_announced = 0;
        let mut update_iter_withdrawn = 0;

        for update in parser1.into_update_iter() {
            if let MrtUpdate::Bgp4MpUpdate(u) = update {
                update_iter_announced += u.message.announced_prefixes.len();
                update_iter_withdrawn += u.message.withdrawn_prefixes.len();
                for attr in &u.message.attributes {
                    match attr {
                        AttributeValue::MpReachNlri(nlri) => {
                            update_iter_announced += nlri.prefixes.len();
                        }
                        AttributeValue::MpUnreachNlri(nlri) => {
                            update_iter_withdrawn += nlri.prefixes.len();
                        }
                        _ => {}
                    }
                }
            }
        }

        // Count prefixes using ElemIterator
        let parser2 = BgpkitParser::new(url).unwrap();
        let mut elem_iter_announced = 0;
        let mut elem_iter_withdrawn = 0;

        for elem in parser2.into_elem_iter() {
            match elem.elem_type {
                ElemType::ANNOUNCE => elem_iter_announced += 1,
                ElemType::WITHDRAW => elem_iter_withdrawn += 1,
            }
        }

        // Counts should match
        assert_eq!(
            update_iter_announced, elem_iter_announced,
            "Announced prefix counts should match"
        );
        assert_eq!(
            update_iter_withdrawn, elem_iter_withdrawn,
            "Withdrawn prefix counts should match"
        );
    }
}
