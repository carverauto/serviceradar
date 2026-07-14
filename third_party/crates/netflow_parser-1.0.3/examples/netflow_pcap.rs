use netflow_parser::NetflowPacket;
use netflow_parser::NetflowParser;
use netflow_parser::variable_versions::ipfix::FlowSetBody;

use etherparse::{SlicedPacket, TransportSlice};
use pcap_parser::LegacyPcapReader;
use pcap_parser::PcapError;
use pcap_parser::traits::PcapReaderIterator;
use std::fs::File;

struct PCAPParser;

impl PCAPParser {
    fn parse_pcap(path: &str) -> Vec<Vec<u8>> {
        let mut reader = Self::open_pcap(path);

        let mut data = vec![];

        loop {
            match reader.next() {
                Ok((offset, block)) => {
                    match block {
                        pcap_parser::PcapBlockOwned::LegacyHeader(_header) => (),
                        pcap_parser::PcapBlockOwned::Legacy(pcap_block) => {
                            if let Ok(eth) = SlicedPacket::from_ethernet(pcap_block.data)
                                && let Some(transport) = eth.transport
                                && let TransportSlice::Udp(udp) = transport
                            {
                                data.push(udp.payload().to_vec());
                            }
                        }
                        // This case should not occur for a valid .pcap file
                        pcap_parser::PcapBlockOwned::NG(_) => {
                            eprintln!(
                                "Warning: Encountered PCAPNG block in what should be a legacy PCAP file."
                            );
                        }
                    }
                    // Important: Consume the bytes that were just parsed
                    reader.consume(offset);
                }
                Err(PcapError::Eof) => {
                    break;
                }
                Err(PcapError::Incomplete(_)) => {
                    reader.refill().expect("Failed to refill buffer");
                }
                Err(e) => {
                    eprintln!("Error while reading PCAP: {:?}", e);
                    break;
                }
            }
        }

        data
    }

    fn open_pcap(path: &str) -> LegacyPcapReader<File> {
        let cargo_home =
            std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".to_string());
        let cargo_home = std::path::Path::new(&cargo_home).join("pcaps");
        let full_path = std::path::Path::new(&cargo_home).join(path);
        let file = File::open(full_path).expect("Failed to open pcap file");
        LegacyPcapReader::new(65536, file).expect("LegacyPcapReader")
    }
}

fn main() {
    let pcap_data = PCAPParser::parse_pcap("IPFIX.pcap");

    let mut parser = NetflowParser::default();
    let mut no_template_packets = vec![];
    let mut parsed_packets = vec![];

    for data in pcap_data.iter() {
        for result in parser.iter_packets(data) {
            match result {
                Ok(packet) => match &packet {
                    NetflowPacket::IPFix(ipfix) => {
                        let has_no_template = ipfix
                            .flowsets
                            .iter()
                            .any(|flow| matches!(flow.body, FlowSetBody::NoTemplate(_)));
                        if has_no_template {
                            no_template_packets.push(data);
                        } else {
                            parsed_packets.push(packet);
                        }
                    }
                    _ => parsed_packets.push(packet),
                },
                Err(e) => println!("Error parsing packet: {:?}", e),
            }
        }
    }
    for item in no_template_packets.iter() {
        for packet in parser.iter_packets(item).flatten() {
            parsed_packets.push(packet);
        }
    }
    for (i, p) in parsed_packets.iter().enumerate() {
        println!("Parsed {}: {:?}", i, p);
    }
}
