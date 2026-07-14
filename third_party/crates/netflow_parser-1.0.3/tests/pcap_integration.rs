//! Integration tests parsing real NetFlow/IPFIX traffic from pcap capture files.

use etherparse::{SlicedPacket, TransportSlice};
use netflow_parser::NetflowParser;
use pcap_parser::traits::PcapReaderIterator;
use pcap_parser::{LegacyPcapReader, PcapBlockOwned, PcapError};
use std::fs::File;

const PCAP_PATH: &str = "pcaps/IPFIX.pcap";

// Verify that the parser can read a pcap file and extract NetFlow packets from UDP payloads
#[test]
fn test_pcap_file_parsing() {
    let file = File::open(PCAP_PATH).expect("Failed to open PCAP file");
    let mut reader = LegacyPcapReader::new(65536, file).expect("Failed to create PCAP reader");
    let mut parser = NetflowParser::default();
    let mut packet_count = 0;
    let mut netflow_packets = 0;

    loop {
        match reader.next() {
            Ok((offset, block)) => {
                match block {
                    PcapBlockOwned::LegacyHeader(_) => (),
                    PcapBlockOwned::Legacy(pcap_block) => {
                        packet_count += 1;
                        if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                            && let Some(transport) = eth.transport
                            && let TransportSlice::Udp(udp) = transport
                        {
                            let parsed = parser.parse_bytes(udp.payload());
                            netflow_packets += parsed.packets.len();
                        }
                    }
                    PcapBlockOwned::NG(_) => {}
                }
                reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                reader.refill().expect("Failed to refill buffer");
            }
            Err(_) => break,
        }
    }

    assert_eq!(packet_count, 6666, "Expected exact PCAP packet count");
    assert_eq!(netflow_packets, 6666, "Expected exact NetFlow packet count");
}

// Verify that IPFIX packets are correctly identified when parsing a pcap capture
#[test]
fn test_pcap_ipfix_parsing() {
    let file = File::open(PCAP_PATH).expect("Failed to open PCAP file");
    let mut reader = LegacyPcapReader::new(65536, file).expect("Failed to create PCAP reader");
    let mut parser = NetflowParser::default();
    let mut ipfix_count = 0;

    loop {
        match reader.next() {
            Ok((offset, block)) => {
                match block {
                    PcapBlockOwned::LegacyHeader(_) => (),
                    PcapBlockOwned::Legacy(pcap_block) => {
                        if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                            && let Some(transport) = eth.transport
                            && let TransportSlice::Udp(udp) = transport
                        {
                            let parsed = parser.parse_bytes(udp.payload());
                            for pkt in parsed.packets {
                                if pkt.is_ipfix() {
                                    ipfix_count += 1;
                                }
                            }
                        }
                    }
                    PcapBlockOwned::NG(_) => {}
                }
                reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                reader.refill().expect("Failed to refill buffer");
            }
            Err(_) => break,
        }
    }

    assert_eq!(
        ipfix_count, 6666,
        "Expected exact IPFIX packet count from PCAP"
    );
}

// Verify that IPFIX templates from pcap traffic are cached and their IDs are retrievable
#[test]
fn test_pcap_template_caching() {
    let file = File::open(PCAP_PATH).expect("Failed to open PCAP file");
    let mut reader = LegacyPcapReader::new(65536, file).expect("Failed to create PCAP reader");
    let mut parser = NetflowParser::default();

    loop {
        match reader.next() {
            Ok((offset, block)) => {
                match block {
                    PcapBlockOwned::LegacyHeader(_) => (),
                    PcapBlockOwned::Legacy(pcap_block) => {
                        if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                            && let Some(transport) = eth.transport
                            && let TransportSlice::Udp(udp) = transport
                        {
                            let _ = parser.parse_bytes(udp.payload());
                        }
                    }
                    PcapBlockOwned::NG(_) => {}
                }
                reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                reader.refill().expect("Failed to refill buffer");
            }
            Err(_) => break,
        }
    }

    // Check that templates were cached
    let ipfix_info = parser.ipfix_cache_info();
    let template_ids = parser.ipfix_template_ids();

    // IPFIX.pcap should have exactly 15 templates (IDs 256-270)
    assert_eq!(
        ipfix_info.current_size, 17,
        "Expected exact IPFIX template cache size"
    );
    assert_eq!(
        template_ids,
        vec![
            256, 257, 258, 259, 260, 261, 262, 263, 264, 265, 266, 267, 268, 269, 270
        ],
        "Expected exact cached template IDs"
    );
}

// Verify that cache metrics (hits, misses) are recorded when parsing pcap traffic
#[test]
fn test_pcap_cache_metrics() {
    let file = File::open(PCAP_PATH).expect("Failed to open PCAP file");
    let mut reader = LegacyPcapReader::new(65536, file).expect("Failed to create PCAP reader");
    let mut parser = NetflowParser::default();

    loop {
        match reader.next() {
            Ok((offset, block)) => {
                match block {
                    PcapBlockOwned::LegacyHeader(_) => (),
                    PcapBlockOwned::Legacy(pcap_block) => {
                        if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                            && let Some(transport) = eth.transport
                            && let TransportSlice::Udp(udp) = transport
                        {
                            let _ = parser.parse_bytes(udp.payload());
                        }
                    }
                    PcapBlockOwned::NG(_) => {}
                }
                reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                reader.refill().expect("Failed to refill buffer");
            }
            Err(_) => break,
        }
    }

    // Check cache metrics — verify we actually parsed IPFIX data from the pcap
    let ipfix_info = parser.ipfix_cache_info();
    let metrics = &ipfix_info.metrics;

    assert_eq!(
        ipfix_info.current_size, 17,
        "Expected exact IPFIX template cache size"
    );
    assert_eq!(metrics.hits, 5754, "Expected exact cache hit count");
    assert_eq!(metrics.misses, 901, "Expected exact cache miss count");
}

// Verify that the iter_packets API produces the same results as parse_bytes from pcap data
#[test]
fn test_pcap_iterator_api() {
    let file = File::open(PCAP_PATH).expect("Failed to open PCAP file");
    let mut reader = LegacyPcapReader::new(65536, file).expect("Failed to create PCAP reader");
    let mut parser = NetflowParser::default();
    let mut netflow_count = 0;

    loop {
        match reader.next() {
            Ok((offset, block)) => {
                match block {
                    PcapBlockOwned::LegacyHeader(_) => (),
                    PcapBlockOwned::Legacy(pcap_block) => {
                        if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                            && let Some(transport) = eth.transport
                            && let TransportSlice::Udp(udp) = transport
                        {
                            // Use iterator API instead of parse_bytes
                            for pkt in parser.iter_packets(udp.payload()) {
                                if pkt.is_ok() {
                                    netflow_count += 1;
                                }
                            }
                        }
                    }
                    PcapBlockOwned::NG(_) => {}
                }
                reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                reader.refill().expect("Failed to refill buffer");
            }
            Err(_) => break,
        }
    }

    assert_eq!(
        netflow_count, 6666,
        "Expected exact NetFlow packet count via iterator API"
    );
}
