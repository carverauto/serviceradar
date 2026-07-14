use std::io::Cursor;

use bgpkit_parser::models::{CommonHeader, EntryType};
use bgpkit_parser::BgpkitParser;

fn build_valid_bgp4mp_zero_len_record() -> Vec<u8> {
    let hdr = CommonHeader {
        timestamp: 1,
        microsecond_timestamp: None,
        entry_type: EntryType::BGP4MP,
        entry_subtype: 0,
        length: 0,
    };
    hdr.encode().to_vec()
}

fn build_bgp4mp_with_len(len: u32) -> Vec<u8> {
    let hdr = CommonHeader {
        timestamp: 2,
        microsecond_timestamp: None,
        entry_type: EntryType::BGP4MP,
        entry_subtype: 0,
        length: len,
    };
    let mut bytes = hdr.encode().to_vec();
    bytes.extend(std::iter::repeat_n(0u8, len as usize));
    bytes
}

fn build_invalid_entry_type_header() -> Vec<u8> {
    // Manually craft a header with an undefined EntryType (e.g., 15)
    let mut bytes = Vec::new();
    bytes.extend(0u32.to_be_bytes()); // timestamp
    bytes.extend(15u16.to_be_bytes()); // invalid entry type (not defined)
    bytes.extend(0u16.to_be_bytes()); // subtype
    bytes.extend(0u32.to_be_bytes()); // length
    bytes
}

#[test]
fn test_raw_record_iterator_yields_valid_record() {
    let mut data = Vec::new();
    data.extend(build_valid_bgp4mp_zero_len_record());

    let cursor = Cursor::new(data);
    let parser = BgpkitParser::from_reader(cursor);
    let mut iter = parser.into_raw_record_iter();

    let rec = iter.next().expect("should yield one record");
    assert_eq!(rec.common_header.entry_type, EntryType::BGP4MP);
    assert_eq!(rec.common_header.length, 0);
    assert_eq!(rec.total_bytes_len(), 12); // 12 bytes header + 0 bytes body

    // then end of stream
    assert!(iter.next().is_none());
}

#[test]
fn test_raw_record_iterator_empty_stream_is_eof() {
    let cursor = Cursor::new(Vec::<u8>::new());
    let parser = BgpkitParser::from_reader(cursor);
    let mut iter = parser.into_raw_record_iter();

    assert!(iter.next().is_none(), "empty stream should be EOF");
}

#[test]
fn test_raw_record_iterator_parse_error_skips_when_no_core_dump() {
    // Stream: [invalid header][valid record]
    let mut data = Vec::new();
    data.extend(build_invalid_entry_type_header());
    data.extend(build_bgp4mp_with_len(0));

    let cursor = Cursor::new(data);
    let parser = BgpkitParser::from_reader(cursor); // core_dump=false by default
    let mut iter = parser.into_raw_record_iter();

    // Iterator should skip the invalid header and yield the valid record
    let rec = iter
        .next()
        .expect("should yield valid record after skipping parse error");
    assert_eq!(rec.common_header.entry_type, EntryType::BGP4MP);
    assert_eq!(rec.total_bytes_len(), 12); // 12 bytes header + 0 bytes body
    assert!(iter.next().is_none());
}

#[test]
fn test_raw_record_iterator_parse_error_stops_when_core_dump_enabled() {
    // Stream: [invalid header][valid record]
    let mut data = Vec::new();
    data.extend(build_invalid_entry_type_header());
    data.extend(build_bgp4mp_with_len(0));

    let cursor = Cursor::new(data);
    let parser = BgpkitParser::from_reader(cursor).enable_core_dump();
    let mut iter = parser.into_raw_record_iter();

    // Iterator should stop on parse error when core_dump is enabled
    assert!(iter.next().is_none());
}

#[test]
fn test_raw_record_iterator_io_error_stops_iteration() {
    // Craft a header that declares 5 bytes but only provide 3 -> triggers IoError in chunk_mrt_record
    let hdr = CommonHeader {
        timestamp: 3,
        microsecond_timestamp: None,
        entry_type: EntryType::BGP4MP,
        entry_subtype: 0,
        length: 5,
    };
    let mut data = hdr.encode().to_vec();
    data.extend([0u8; 3]); // insufficient bytes

    let cursor = Cursor::new(data);
    let parser = BgpkitParser::from_reader(cursor);
    let mut iter = parser.into_raw_record_iter();

    // On IoError branch, iterator stops and returns None immediately
    assert!(iter.next().is_none());
}
