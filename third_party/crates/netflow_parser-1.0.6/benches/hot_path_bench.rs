use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use netflow_parser::scoped_parser::AutoScopedParser;
use netflow_parser::{NetflowPacket, NetflowParser};
use std::hint::black_box;
use std::net::SocketAddr;

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

#[derive(Clone, Copy)]
enum Protocol {
    V9,
    Ipfix,
}

impl Protocol {
    fn name(self) -> &'static str {
        match self {
            Self::V9 => "v9",
            Self::Ipfix => "ipfix",
        }
    }

    fn template_packet(self) -> Vec<u8> {
        match self {
            Self::V9 => v9_template_packet(),
            Self::Ipfix => ipfix_template_packet(),
        }
    }

    fn data_packet(self, flow_count: u16) -> Vec<u8> {
        match self {
            Self::V9 => v9_data_packet(flow_count),
            Self::Ipfix => ipfix_data_packet(flow_count),
        }
    }

    fn assert_decoded_records(self, packets: &[NetflowPacket], expected: usize) {
        assert_eq!(packets.len(), 1, "fixture must decode one outer packet");
        let actual: usize = match (self, &packets[0]) {
            (Self::V9, NetflowPacket::V9(packet)) => packet
                .flowsets
                .iter()
                .map(|flowset| match &flowset.body {
                    netflow_parser::variable_versions::v9::FlowSetBody::Data(data) => {
                        data.fields.len()
                    }
                    _ => 0,
                })
                .sum(),
            (Self::Ipfix, NetflowPacket::IPFix(packet)) => packet
                .flowsets
                .iter()
                .map(|flowset| match &flowset.body {
                    netflow_parser::variable_versions::ipfix::FlowSetBody::Data(data) => {
                        data.fields.len()
                    }
                    _ => 0,
                })
                .sum(),
            _ => panic!("fixture decoded as the wrong protocol"),
        };
        assert_eq!(actual, expected, "fixture decoded-record count mismatch");
    }
}

#[derive(Clone, Copy)]
enum Scenario {
    DirectParse,
    DirectIterator,
    AutoParse,
    AutoIterator,
}

impl Scenario {
    fn name(self) -> &'static str {
        match self {
            Self::DirectParse => "direct/parse",
            Self::DirectIterator => "direct/iterator",
            Self::AutoParse => "auto/parse",
            Self::AutoIterator => "auto/iterator",
        }
    }
}

fn bench_warmed_hot_paths(c: &mut Criterion) {
    let source = SocketAddr::from(([192, 0, 2, 1], 2055));

    for protocol in [Protocol::V9, Protocol::Ipfix] {
        let template = protocol.template_packet();
        for scenario in [
            Scenario::DirectParse,
            Scenario::DirectIterator,
            Scenario::AutoParse,
            Scenario::AutoIterator,
        ] {
            let mut group =
                c.benchmark_group(format!("Hot Path/{}/{}", protocol.name(), scenario.name()));

            for flow_count in [1u16, 1000] {
                let data = protocol.data_packet(flow_count);
                group.throughput(Throughput::Elements(u64::from(flow_count)));
                group.bench_with_input(
                    BenchmarkId::from_parameter(flow_count),
                    &data,
                    |b, packet| match scenario {
                        Scenario::DirectParse => {
                            let mut parser = NetflowParser::default();
                            assert!(parser.parse_bytes(&template).is_ok());
                            let result = parser.parse_bytes(packet);
                            assert!(result.is_ok());
                            protocol.assert_decoded_records(
                                &result.packets,
                                usize::from(flow_count),
                            );
                            b.iter(|| {
                                drop(black_box(
                                    parser.parse_bytes(black_box(packet.as_slice())),
                                ));
                            });
                        }
                        Scenario::DirectIterator => {
                            let mut parser = NetflowParser::default();
                            assert!(parser.parse_bytes(&template).is_ok());
                            let packets = parser
                                .iter_packets(packet)
                                .map(Result::unwrap)
                                .collect::<Vec<_>>();
                            protocol.assert_decoded_records(&packets, usize::from(flow_count));
                            b.iter(|| {
                                for result in parser.iter_packets(black_box(packet.as_slice()))
                                {
                                    black_box(result.unwrap());
                                }
                            });
                        }
                        Scenario::AutoParse => {
                            let mut parser = AutoScopedParser::new();
                            assert!(parser.parse_from_source(source, &template).is_ok());
                            let result = parser.parse_from_source(source, packet);
                            assert!(result.is_ok());
                            protocol.assert_decoded_records(
                                &result.packets,
                                usize::from(flow_count),
                            );
                            b.iter(|| {
                                drop(black_box(
                                    parser.parse_from_source(
                                        source,
                                        black_box(packet.as_slice()),
                                    ),
                                ));
                            });
                        }
                        Scenario::AutoIterator => {
                            let mut parser = AutoScopedParser::new();
                            assert!(parser.parse_from_source(source, &template).is_ok());
                            let packets = parser
                                .iter_packets_from_source(source, packet)
                                .unwrap()
                                .map(Result::unwrap)
                                .collect::<Vec<_>>();
                            protocol.assert_decoded_records(&packets, usize::from(flow_count));
                            b.iter(|| {
                                let iterator = parser
                                    .iter_packets_from_source(
                                        source,
                                        black_box(packet.as_slice()),
                                    )
                                    .unwrap();
                                for result in iterator {
                                    black_box(result.unwrap());
                                }
                            });
                        }
                    },
                );
            }
            group.finish();
        }
    }
}

criterion_group!(benches, bench_warmed_hot_paths);
criterion_main!(benches);
