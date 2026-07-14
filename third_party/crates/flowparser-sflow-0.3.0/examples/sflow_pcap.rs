use flowparser_sflow::SflowParser;
use pcap_parser::traits::PcapReaderIterator;
use pcap_parser::*;
use std::fs::File;
use std::io::BufReader;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("Usage: {} <pcap-file>", args[0]);
        std::process::exit(1);
    }

    let file = File::open(&args[1]).expect("Failed to open pcap file");
    let mut reader = BufReader::new(file);

    let parser = SflowParser::default();
    let mut packet_count = 0;

    // Read magic bytes to detect format, then seek back
    let magic = {
        use std::io::Read;
        let mut buf = [0u8; 4];
        reader
            .read_exact(&mut buf)
            .expect("Failed to read file header");
        use std::io::Seek;
        reader
            .seek(std::io::SeekFrom::Start(0))
            .expect("Failed to seek");
        u32::from_le_bytes(buf)
    };

    if magic == 0x0A0D0D0A {
        // pcap-ng
        let mut pcap_reader =
            PcapNGReader::new(65535, reader).expect("Failed to create pcap-ng reader");
        run_pcapng(&mut pcap_reader, &parser, &mut packet_count);
    } else {
        // Legacy pcap (0xa1b2c3d4 or 0xd4c3b2a1)
        let mut pcap_reader =
            LegacyPcapReader::new(65535, reader).expect("Failed to create pcap reader");
        run_legacy(&mut pcap_reader, &parser, &mut packet_count);
    }

    println!("Parsed {} sFlow datagrams", packet_count);
}

fn run_pcapng<R: std::io::Read>(
    pcap_reader: &mut PcapNGReader<R>,
    parser: &SflowParser,
    packet_count: &mut usize,
) {
    loop {
        match pcap_reader.next() {
            Ok((offset, block)) => {
                if let PcapBlockOwned::NG(Block::EnhancedPacket(epb)) = block {
                    process_packet(epb.data, parser, packet_count);
                }
                pcap_reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                pcap_reader.refill().expect("Failed to refill");
            }
            Err(e) => {
                eprintln!("Error reading pcap: {:?}", e);
                break;
            }
        }
    }
}

fn run_legacy<R: std::io::Read>(
    pcap_reader: &mut LegacyPcapReader<R>,
    parser: &SflowParser,
    packet_count: &mut usize,
) {
    loop {
        match pcap_reader.next() {
            Ok((offset, block)) => {
                if let PcapBlockOwned::Legacy(packet) = block {
                    process_packet(packet.data, parser, packet_count);
                }
                pcap_reader.consume(offset);
            }
            Err(PcapError::Eof) => break,
            Err(PcapError::Incomplete(_)) => {
                pcap_reader.refill().expect("Failed to refill");
            }
            Err(e) => {
                eprintln!("Error reading pcap: {:?}", e);
                break;
            }
        }
    }
}

fn process_packet(data: &[u8], parser: &SflowParser, packet_count: &mut usize) {
    if let Some(payload) = extract_udp_payload(data) {
        let result = parser.parse_bytes(payload);
        for datagram in &result.datagrams {
            *packet_count += 1;
            println!(
                "Packet {}: seq={} samples={}",
                packet_count,
                datagram.sequence_number,
                datagram.samples.len()
            );
            println!("{:?}", datagram);
        }
    }
}

fn extract_udp_payload(data: &[u8]) -> Option<&[u8]> {
    use etherparse::SlicedPacket;
    let packet = SlicedPacket::from_ethernet(data).ok()?;
    match packet.transport {
        Some(etherparse::TransportSlice::Udp(udp)) => Some(udp.payload()),
        _ => None,
    }
}
