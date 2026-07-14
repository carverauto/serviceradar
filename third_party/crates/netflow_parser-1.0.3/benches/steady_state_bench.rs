use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

/// Create a V9 template-only packet (template ID 256, 6 fields).
fn v9_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1 (template flowset only)
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Template FlowSet
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x20, // Length = 32 (4 header + 4 template header + 24 fields)
        0x01, 0x00, // Template ID = 256
        0x00, 0x06, // Field count = 6
        0x00, 0x08, 0x00, 0x04, // sourceIPv4Address (4 bytes)
        0x00, 0x0C, 0x00, 0x04, // destinationIPv4Address (4 bytes)
        0x00, 0x07, 0x00, 0x02, // sourceTransportPort (2 bytes)
        0x00, 0x0B, 0x00, 0x02, // destinationTransportPort (2 bytes)
        0x00, 0x01, 0x00, 0x04, // inBytes (4 bytes)
        0x00, 0x02, 0x00, 0x04, // inPkts (4 bytes)
    ]
}

/// Create a V9 data-only packet with N flow records (20 bytes each).
fn v9_data_packet(flow_count: u16) -> Vec<u8> {
    let record_size = 20u16; // 4+4+2+2+4+4
    let data_length = 4 + (flow_count * record_size);
    let mut packet = vec![
        0x00,
        0x09, // Version 9
        0x00,
        0x01, // Count = 1 (data flowset only)
        0x00,
        0x00,
        0x00,
        0x02, // SysUptime
        0x00,
        0x00,
        0x00,
        0x02, // Unix seconds
        0x00,
        0x00,
        0x00,
        0x02, // Sequence
        0x00,
        0x00,
        0x00,
        0x01, // Source ID
        // Data FlowSet
        0x01,
        0x00, // FlowSet ID = 256 (data)
        (data_length >> 8) as u8,
        (data_length & 0xFF) as u8,
    ];
    for i in 0..flow_count {
        let i_lo = (i & 0xFF) as u8;
        let i_hi = ((i >> 8) & 0xFF) as u8;
        packet.extend_from_slice(&[
            0x0A, 0x00, i_hi, i_lo, // src IP
            0x0A, 0x00, 0x01, i_lo, // dst IP
            0x00, 0x50, // src port 80
            0x01, 0xBB, // dst port 443
            0x00, 0x00, 0x05, 0x00, // inBytes
            0x00, 0x00, 0x00, 0x0A, // inPkts
        ]);
    }
    packet
}

/// Create an IPFIX template-only packet (template ID 256, 6 fields).
fn ipfix_template_packet() -> Vec<u8> {
    let set_length = 4 + 4 + 24; // set header + template header + 6 fields * 4
    let total_length = 16 + set_length;
    vec![
        0x00,
        0x0A, // Version 10 (IPFIX)
        (total_length >> 8) as u8,
        (total_length & 0xFF) as u8,
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
        (set_length >> 8) as u8,
        (set_length & 0xFF) as u8,
        0x01,
        0x00, // Template ID = 256
        0x00,
        0x06, // Field count = 6
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
        0x00,
        0x01,
        0x00,
        0x04, // octetDeltaCount
        0x00,
        0x02,
        0x00,
        0x04, // packetDeltaCount
    ]
}

/// Create an IPFIX data-only packet with N flow records (20 bytes each).
fn ipfix_data_packet(flow_count: u16) -> Vec<u8> {
    let record_size = 20u16;
    let data_set_length = 4 + (flow_count * record_size);
    let total_length = 16u16 + data_set_length;
    let mut packet = vec![
        0x00,
        0x0A, // Version 10 (IPFIX)
        (total_length >> 8) as u8,
        (total_length & 0xFF) as u8,
        0x00,
        0x00,
        0x00,
        0x02, // Export time
        0x00,
        0x00,
        0x00,
        0x02, // Sequence
        0x00,
        0x00,
        0x00,
        0x01, // Observation domain
        // Data Set
        0x01,
        0x00, // Set ID = 256
        (data_set_length >> 8) as u8,
        (data_set_length & 0xFF) as u8,
    ];
    for i in 0..flow_count {
        let i_lo = (i & 0xFF) as u8;
        let i_hi = ((i >> 8) & 0xFF) as u8;
        packet.extend_from_slice(&[
            0x0A, 0x00, i_hi, i_lo, // src IP
            0x0A, 0x00, 0x01, i_lo, // dst IP
            0x00, 0x50, // src port 80
            0x01, 0xBB, // dst port 443
            0x00, 0x00, 0x05, 0x00, // octetDeltaCount
            0x00, 0x00, 0x00, 0x0A, // packetDeltaCount
        ]);
    }
    packet
}

fn bench_v9_steady_state(c: &mut Criterion) {
    let mut group = c.benchmark_group("V9 Steady State");
    let template = v9_template_packet();

    for flow_count in [5, 10, 30, 100] {
        let data = v9_data_packet(flow_count);
        let size = data.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} flows ({} bytes)", flow_count, size)),
            &data,
            |b, pkt| {
                let mut parser = NetflowParser::default();
                // Warm up: parse template packet once
                let _ = parser.parse_bytes(&template);
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(pkt));
                });
            },
        );
    }

    group.finish();
}

fn bench_ipfix_steady_state(c: &mut Criterion) {
    let mut group = c.benchmark_group("IPFIX Steady State");
    let template = ipfix_template_packet();

    for flow_count in [5, 10, 30, 100] {
        let data = ipfix_data_packet(flow_count);
        let size = data.len();

        group.throughput(Throughput::Bytes(size as u64));
        group.bench_with_input(
            BenchmarkId::from_parameter(format!("{} flows ({} bytes)", flow_count, size)),
            &data,
            |b, pkt| {
                let mut parser = NetflowParser::default();
                // Warm up: parse template packet once
                let _ = parser.parse_bytes(&template);
                b.iter(|| {
                    let _ = parser.parse_bytes(black_box(pkt));
                });
            },
        );
    }

    group.finish();
}

criterion_group!(benches, bench_v9_steady_state, bench_ipfix_steady_state);
criterion_main!(benches);
