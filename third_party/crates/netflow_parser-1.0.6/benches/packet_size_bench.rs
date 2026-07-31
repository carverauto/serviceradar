use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

/// Helper to create V5 packet with N flow records
fn create_v5_packet(flow_count: u16) -> Vec<u8> {
    let mut packet = vec![
        0x00,
        0x05, // Version 5
        (flow_count >> 8) as u8,
        (flow_count & 0xFF) as u8, // Count
        0x03,
        0x00,
        0x04,
        0x00, // SysUptime
        0x05,
        0x00,
        0x06,
        0x07, // Unix seconds
        0x08,
        0x09,
        0x00,
        0x01, // Unix nsecs
        0x02,
        0x03,
        0x04,
        0x05, // Sequence
        0x06,
        0x07,
        0x08,
        0x09, // Engine
    ];

    // Each V5 flow record is 48 bytes
    let flow_record = [
        0x0A, 0x00, 0x00, 0x01, // src_addr
        0x0A, 0x00, 0x00, 0x02, // dst_addr
        0x00, 0x00, 0x00, 0x00, // next_hop
        0x00, 0x01, 0x00, 0x02, // input/output
        0x00, 0x00, 0x00, 0x0A, // d_pkts
        0x00, 0x00, 0x05, 0x00, // d_octets
        0x00, 0x00, 0x00, 0x01, // first
        0x00, 0x00, 0x00, 0x02, // last
        0x00, 0x50, 0x00, 0x51, // src_port/dst_port
        0x00, 0x00, 0x06, 0x00, // pad1/tcp_flags/protocol(TCP=6)/tos
        0x00, 0x01, 0x00, 0x02, // src_as/dst_as
        0x18, 0x18, 0x00, 0x00, // src_mask/dst_mask/pad2
    ];

    for _ in 0..flow_count {
        packet.extend_from_slice(&flow_record);
    }

    packet
}

/// Helper to create V9 template + data packet with N flow records
fn create_v9_packet(flow_count: u16) -> Vec<u8> {
    let mut packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x02, // Count = 2 (template + data)
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Template FlowSet
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x14, // Length = 20 (4 header + 16 fields)
        0x01, 0x00, // Template ID = 256
        0x00, 0x04, // Field count = 4
        0x00, 0x08, 0x00, 0x04, // Field: sourceIPv4Address, length 4
        0x00, 0x0C, 0x00, 0x04, // Field: destinationIPv4Address, length 4
        0x00, 0x07, 0x00, 0x02, // Field: sourceTransportPort, length 2
        0x00, 0x0B, 0x00, 0x02, // Field: destinationTransportPort, length 2
    ];

    // Data FlowSet header
    let data_length = 4 + (flow_count * 12); // Header + (4+4+2+2)*N
    packet.extend_from_slice(&[
        0x01,
        0x00, // FlowSet ID = 256 (data)
        (data_length >> 8) as u8,
        (data_length & 0xFF) as u8, // Length
    ]);

    // Data records (12 bytes each: 4+4+2+2)
    for i in 0..flow_count {
        packet.extend_from_slice(&[
            0x0A,
            0x00,
            0x00,
            (i & 0xFF) as u8, // src IP
            0x0A,
            0x00,
            0x01,
            (i & 0xFF) as u8, // dst IP
            0x00,
            0x50, // src port
            0x00,
            0x51, // dst port
        ]);
    }

    packet
}

/// Helper to create IPFIX template + data packet with N flow records
fn create_ipfix_packet(flow_count: u16) -> Vec<u8> {
    let template_set_length = 24u16; // Set header (4) + template header (4) + 4 fields (16)
    let data_record_size = 12u16; // 4+4+2+2
    let data_set_length = 4 + (flow_count * data_record_size);
    let total_length = 16 + template_set_length + data_set_length;

    let mut packet = vec![
        0x00,
        0x0A, // Version 10 (IPFIX)
        (total_length >> 8) as u8,
        (total_length & 0xFF) as u8, // Length
        0x00,
        0x00,
        0x00,
        0x01, // Export time
        0x00,
        0x00,
        0x00,
        0x01, // Sequence
        0x00,
        0x00,
        0x00,
        0x01, // Observation domain
        // Template Set
        0x00,
        0x02, // Set ID = 2 (template)
        0x00,
        0x18, // Length = 24
        0x01,
        0x00, // Template ID = 256
        0x00,
        0x04, // Field count = 4
        0x00,
        0x08,
        0x00,
        0x04, // sourceIPv4Address
        0x00,
        0x0C,
        0x00,
        0x04, // destinationIPv4Address
        0x00,
        0x07,
        0x00,
        0x02, // sourceTransportPort
        0x00,
        0x0B,
        0x00,
        0x02, // destinationTransportPort
        // Data Set
        0x01,
        0x00, // Set ID = 256 (data)
        (data_set_length >> 8) as u8,
        (data_set_length & 0xFF) as u8, // Length
    ];

    // Data records
    for i in 0..flow_count {
        packet.extend_from_slice(&[
            0x0A,
            0x00,
            0x00,
            (i & 0xFF) as u8, // src IP
            0x0A,
            0x00,
            0x01,
            (i & 0xFF) as u8, // dst IP
            0x00,
            0x50, // src port
            0x00,
            0x51, // dst port
        ]);
    }

    packet
}

fn bench_v5_packet_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("V5 Packet Sizes");

    // V5 max is 30 flows per packet (MAX_FLOWS). Don't benchmark invalid counts.
    for flow_count in [1, 10, 30].iter() {
        let packet = create_v5_packet(*flow_count);
        let size = packet.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} flows ({} bytes)", flow_count, size)),
            &packet,
            |b, pkt| {
                let mut parser = NetflowParser::default();
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(pkt));
                });
            },
        );
    }

    group.finish();
}

fn bench_v9_packet_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("V9 Packet Sizes");

    for flow_count in [1, 10, 30, 100].iter() {
        let packet = create_v9_packet(*flow_count);
        let size = packet.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} flows ({} bytes)", flow_count, size)),
            &packet,
            |b, pkt| {
                let mut parser = NetflowParser::default();
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(pkt));
                });
            },
        );
    }

    group.finish();
}

fn bench_ipfix_packet_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("IPFIX Packet Sizes");

    for flow_count in [1, 10, 30, 100].iter() {
        let packet = create_ipfix_packet(*flow_count);
        let size = packet.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} flows ({} bytes)", flow_count, size)),
            &packet,
            |b, pkt| {
                let mut parser = NetflowParser::default();
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(pkt));
                });
            },
        );
    }

    group.finish();
}

fn bench_mixed_stream_sizes(c: &mut Criterion) {
    let mut group = c.benchmark_group("Mixed Stream Sizes");

    for packet_count in [10, 50, 100, 500].iter() {
        let mut stream = Vec::new();

        // Create mixed stream with V5, V9, and IPFIX packets
        for i in 0..*packet_count {
            match i % 3 {
                0 => stream.extend_from_slice(&create_v5_packet(5)),
                1 => stream.extend_from_slice(&create_v9_packet(5)),
                _ => stream.extend_from_slice(&create_ipfix_packet(5)),
            }
        }

        let size = stream.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} packets ({} bytes)", packet_count, size)),
            &stream,
            |b, data| {
                let mut parser = NetflowParser::default();
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(data));
                });
            },
        );
    }

    group.finish();
}

fn bench_iterator_vs_collect(c: &mut Criterion) {
    let mut group = c.benchmark_group("Iterator vs Collect");

    let packet = create_v5_packet(30);

    group.bench_function("parse_bytes (collects Vec)", |b| {
        let mut parser = NetflowParser::default();
        b.iter(|| {
            let result = parser.parse_bytes(black_box(&packet));
            black_box(result.packets.len());
        });
    });

    group.bench_function("iter_packets (lazy iterator)", |b| {
        let mut parser = NetflowParser::default();
        b.iter(|| {
            let count = parser
                .iter_packets(black_box(&packet))
                .filter(|r| r.is_ok())
                .count();
            black_box(count);
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_v5_packet_sizes,
    bench_v9_packet_sizes,
    bench_ipfix_packet_sizes,
    bench_mixed_stream_sizes,
    bench_iterator_vs_collect
);
criterion_main!(benches);
