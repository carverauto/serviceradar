use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use netflow_parser::NetflowParser;
use std::hint::black_box;

fn v9_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x20, // Length = 32
        0x01, 0x00, // Template ID = 256
        0x00, 0x06, // Field count = 6
        0x00, 0x08, 0x00, 0x04, // sourceIPv4Address
        0x00, 0x0C, 0x00, 0x04, // destinationIPv4Address
        0x00, 0x07, 0x00, 0x02, // sourceTransportPort
        0x00, 0x0B, 0x00, 0x02, // destinationTransportPort
        0x00, 0x01, 0x00, 0x04, // inBytes
        0x00, 0x02, 0x00, 0x04, // inPkts
    ]
}

fn v9_data_packet(flow_count: u16) -> Vec<u8> {
    let record_size = 20u16;
    let data_length = 4 + flow_count * record_size;
    let mut packet = vec![
        0x00,
        0x09, // Version 9
        0x00,
        0x01, // Count = 1
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
        0x01,
        0x00, // FlowSet ID = 256
        (data_length >> 8) as u8,
        (data_length & 0xFF) as u8,
    ];

    for i in 0..flow_count {
        let i_lo = (i & 0xFF) as u8;
        let i_hi = ((i >> 8) & 0xFF) as u8;
        packet.extend_from_slice(&[
            0x0A, 0x00, i_hi, i_lo, // src IP
            0x0A, 0x00, 0x01, i_lo, // dst IP
            0x00, 0x50, // src port
            0x01, 0xBB, // dst port
            0x00, 0x00, 0x05, 0x00, // inBytes
            0x00, 0x00, 0x00, 0x0A, // inPkts
        ]);
    }

    packet
}

fn ipfix_template_packet() -> Vec<u8> {
    let set_length = 4 + 4 + 24;
    let total_length = 16 + set_length;
    vec![
        0x00,
        0x0A, // Version 10
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

fn ipfix_data_packet(flow_count: u16) -> Vec<u8> {
    let record_size = 20u16;
    let data_set_length = 4 + flow_count * record_size;
    let total_length = 16u16 + data_set_length;
    let mut packet = vec![
        0x00,
        0x0A, // Version 10
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
            0x00, 0x50, // src port
            0x01, 0xBB, // dst port
            0x00, 0x00, 0x05, 0x00, // octetDeltaCount
            0x00, 0x00, 0x00, 0x0A, // packetDeltaCount
        ]);
    }

    packet
}

fn bench_warm_v9_data_hot_path(c: &mut Criterion) {
    let template = v9_template_packet();
    let mut group = c.benchmark_group("Hot Path V9 Data");

    for flow_count in [100u16, 500, 1000] {
        let data = v9_data_packet(flow_count);
        group.throughput(Throughput::Bytes(data.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(flow_count), &data, |b, pkt| {
            let mut parser = NetflowParser::default();
            let template_result = parser.parse_bytes(&template);
            assert!(template_result.error.is_none());
            assert_eq!(template_result.packets.len(), 1);

            b.iter(|| {
                let result = parser.parse_bytes(black_box(pkt));
                black_box(result.packets.len());
            });
        });
    }

    group.finish();
}

fn bench_warm_ipfix_data_hot_path(c: &mut Criterion) {
    let template = ipfix_template_packet();
    let mut group = c.benchmark_group("Hot Path IPFIX Data");

    for flow_count in [100u16, 500, 1000] {
        let data = ipfix_data_packet(flow_count);
        group.throughput(Throughput::Bytes(data.len() as u64));
        group.bench_with_input(BenchmarkId::from_parameter(flow_count), &data, |b, pkt| {
            let mut parser = NetflowParser::default();
            let template_result = parser.parse_bytes(&template);
            assert!(template_result.error.is_none());
            assert_eq!(template_result.packets.len(), 1);

            b.iter(|| {
                let result = parser.parse_bytes(black_box(pkt));
                black_box(result.packets.len());
            });
        });
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_warm_v9_data_hot_path,
    bench_warm_ipfix_data_hot_path
);
criterion_main!(benches);
