use flowparser_sflow::{
    AddressType, FlowRecord, SflowDatagram, SflowSample,
};
use flowparser_sflow::samples::FlowSample;
use log::debug;
use std::net::SocketAddr;

// Include generated protobuf code
pub mod flowpb {
    include!(concat!(env!("OUT_DIR"), "/flowpb.rs"));
}

pub struct Converter {
    pub datagram: SflowDatagram,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
}

impl Converter {
    pub fn new(datagram: SflowDatagram, sampler_addr: SocketAddr, receive_time_ns: u64) -> Self {
        Self {
            datagram,
            sampler_addr,
            receive_time_ns,
        }
    }

    /// Convert all flow samples in the datagram to FlowMessages.
    /// Counter and expanded counter samples are skipped.
    pub fn convert(&self) -> Vec<flowpb::FlowMessage> {
        let mut messages = Vec::new();

        for sample in &self.datagram.samples {
            match sample {
                SflowSample::Flow(flow_sample) => {
                    if let Some(msg) = self.convert_flow_sample(flow_sample) {
                        messages.push(msg);
                    }
                }
                SflowSample::ExpandedFlow(expanded) => {
                    if let Some(msg) = self.convert_flow_sample_from_records(
                        &expanded.records,
                        expanded.sampling_rate,
                        expanded.input_value,
                        expanded.output_value,
                    ) {
                        messages.push(msg);
                    }
                }
                SflowSample::Counter(_) | SflowSample::ExpandedCounter(_) => {
                    // Skip counter samples — out of scope
                }
                SflowSample::Unknown { .. } => {
                    debug!("Skipping unknown sFlow sample type");
                }
            }
        }

        messages
    }

    fn convert_flow_sample(
        &self,
        sample: &FlowSample,
    ) -> Option<flowpb::FlowMessage> {
        self.convert_flow_sample_from_records(
            &sample.records,
            sample.sampling_rate,
            sample.input,
            sample.output,
        )
    }

    fn convert_flow_sample_from_records(
        &self,
        records: &[FlowRecord],
        sampling_rate: u32,
        input: u32,
        output: u32,
    ) -> Option<flowpb::FlowMessage> {
        let mut msg = flowpb::FlowMessage {
            r#type: i32::from(flowpb::flow_message::FlowType::Sflow5),
            time_received_ns: self.receive_time_ns,
            sampler_address: address_type_to_bytes(&self.datagram.agent_address),
            sequence_num: self.datagram.sequence_number,
            sampling_rate: u64::from(sampling_rate),
            packets: 1, // sFlow samples individual packets
            in_if: input,
            out_if: output,
            ..Default::default()
        };

        let mut has_ip_record = false;

        for record in records {
            match record {
                FlowRecord::SampledIpv4(ipv4) => {
                    msg.src_addr = ipv4.src_ip.octets().to_vec();
                    msg.dst_addr = ipv4.dst_ip.octets().to_vec();
                    msg.src_port = ipv4.src_port;
                    msg.dst_port = ipv4.dst_port;
                    msg.proto = ipv4.protocol;
                    msg.tcp_flags = ipv4.tcp_flags;
                    msg.ip_tos = ipv4.tos;
                    msg.bytes = u64::from(ipv4.length);
                    msg.etype = 0x0800; // IPv4
                    msg.protocol_name = protocol_name(ipv4.protocol);
                    has_ip_record = true;
                }
                FlowRecord::SampledIpv6(ipv6) => {
                    msg.src_addr = ipv6.src_ip.octets().to_vec();
                    msg.dst_addr = ipv6.dst_ip.octets().to_vec();
                    msg.src_port = ipv6.src_port;
                    msg.dst_port = ipv6.dst_port;
                    msg.proto = ipv6.protocol;
                    msg.tcp_flags = ipv6.tcp_flags;
                    msg.bytes = u64::from(ipv6.length);
                    msg.etype = 0x86DD; // IPv6
                    msg.protocol_name = protocol_name(ipv6.protocol);
                    has_ip_record = true;
                }
                FlowRecord::RawPacketHeader(raw) => {
                    if !has_ip_record {
                        msg.bytes = u64::from(raw.frame_length);
                        msg.etype = raw.header_protocol;
                    }
                }
                FlowRecord::ExtendedSwitch(sw) => {
                    msg.src_vlan = sw.src_vlan;
                    msg.dst_vlan = sw.dst_vlan;
                }
                FlowRecord::ExtendedRouter(router) => {
                    msg.next_hop = address_type_to_bytes(&router.next_hop);
                    msg.src_net = router.src_mask_len;
                    msg.dst_net = router.dst_mask_len;
                }
                FlowRecord::ExtendedGateway(gw) => {
                    msg.src_as = gw.src_as;
                    msg.dst_as = gw.as_number;
                    msg.bgp_next_hop = address_type_to_bytes(&gw.next_hop);
                    msg.bgp_communities = gw.communities.clone();
                    // Flatten AS path segments into a single list
                    msg.as_path = gw
                        .as_path_segments
                        .iter()
                        .flat_map(|seg| seg.values.iter().copied())
                        .collect();
                }
                _ => {
                    // SampledEthernet, ExtendedUser, ExtendedUrl, Unknown — skip
                }
            }
        }

        if !has_ip_record && msg.bytes == 0 {
            debug!(
                "Flow sample from {} has no typed IP records and zero bytes",
                self.sampler_addr
            );
        }

        Some(msg)
    }
}

/// Convert an sFlow AddressType to raw bytes for protobuf.
pub fn address_type_to_bytes(addr: &AddressType) -> Vec<u8> {
    match addr {
        AddressType::IPv4(v4) => v4.octets().to_vec(),
        AddressType::IPv6(v6) => v6.octets().to_vec(),
    }
}

/// Check if a flow message is valid (not degenerate).
pub fn is_valid_flow(msg: &flowpb::FlowMessage) -> bool {
    msg.bytes > 0 || msg.packets > 0
}

/// Map protocol number to human-readable name.
fn protocol_name(proto: u32) -> String {
    match proto {
        1 => "ICMP".to_string(),
        2 => "IGMP".to_string(),
        6 => "TCP".to_string(),
        17 => "UDP".to_string(),
        41 => "IPv6-in-IPv4".to_string(),
        47 => "GRE".to_string(),
        50 => "ESP".to_string(),
        51 => "AH".to_string(),
        58 => "ICMPv6".to_string(),
        89 => "OSPF".to_string(),
        132 => "SCTP".to_string(),
        _ => format!("Proto({})", proto),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flowparser_sflow::datagram::AddressType;
    use flowparser_sflow::flow_records::*;
    use flowparser_sflow::flow_records::extended_gateway::AsPathSegment;
    use flowparser_sflow::samples::{FlowSample, SflowSample};
    use flowparser_sflow::samples::counter_sample::CounterSample;
    use flowparser_sflow::SflowDatagram;
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

    fn make_datagram(samples: Vec<SflowSample>) -> SflowDatagram {
        SflowDatagram {
            version: 5,
            agent_address: AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 1)),
            sub_agent_id: 0,
            sequence_number: 42,
            uptime: 1000,
            samples,
        }
    }

    fn peer_addr() -> SocketAddr {
        "192.168.1.100:6343".parse().unwrap()
    }

    // Task 8.1: SampledIpv4 → FlowMessage
    #[test]
    fn test_sampled_ipv4_conversion() {
        let sample = SflowSample::Flow(FlowSample {
            sequence_number: 1,
            source_id_type: 0,
            source_id_index: 1,
            sampling_rate: 512,
            sample_pool: 1024,
            drops: 0,
            input: 3,
            output: 5,
            records: vec![FlowRecord::SampledIpv4(SampledIpv4 {
                length: 1500,
                protocol: 6,
                src_ip: Ipv4Addr::new(10, 1, 2, 3),
                dst_ip: Ipv4Addr::new(10, 4, 5, 6),
                src_port: 12345,
                dst_port: 80,
                tcp_flags: 0x02, // SYN
                tos: 0,
            })],
        });

        let datagram = make_datagram(vec![sample]);
        let converter = Converter::new(datagram, peer_addr(), 1_000_000_000);
        let messages = converter.convert();

        assert_eq!(messages.len(), 1);
        let msg = &messages[0];
        assert_eq!(
            msg.r#type,
            i32::from(flowpb::flow_message::FlowType::Sflow5)
        );
        assert_eq!(msg.src_addr, Ipv4Addr::new(10, 1, 2, 3).octets().to_vec());
        assert_eq!(msg.dst_addr, Ipv4Addr::new(10, 4, 5, 6).octets().to_vec());
        assert_eq!(msg.src_port, 12345);
        assert_eq!(msg.dst_port, 80);
        assert_eq!(msg.proto, 6);
        assert_eq!(msg.tcp_flags, 0x02);
        assert_eq!(msg.ip_tos, 0);
        assert_eq!(msg.bytes, 1500);
        assert_eq!(msg.packets, 1);
        assert_eq!(msg.etype, 0x0800);
        assert_eq!(msg.sampling_rate, 512);
        assert_eq!(msg.in_if, 3);
        assert_eq!(msg.out_if, 5);
        assert_eq!(msg.sequence_num, 42);
        assert_eq!(msg.time_received_ns, 1_000_000_000);
        assert_eq!(
            msg.sampler_address,
            Ipv4Addr::new(10, 0, 0, 1).octets().to_vec()
        );
        assert_eq!(msg.protocol_name, "TCP");
    }

    // Task 8.2: SampledIpv6 → FlowMessage
    #[test]
    fn test_sampled_ipv6_conversion() {
        let sample = SflowSample::Flow(FlowSample {
            sequence_number: 2,
            source_id_type: 0,
            source_id_index: 1,
            sampling_rate: 256,
            sample_pool: 512,
            drops: 0,
            input: 1,
            output: 2,
            records: vec![FlowRecord::SampledIpv6(SampledIpv6 {
                length: 1400,
                protocol: 17,
                src_ip: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1),
                dst_ip: Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2),
                src_port: 5000,
                dst_port: 53,
                tcp_flags: 0,
                priority: 0,
            })],
        });

        let datagram = make_datagram(vec![sample]);
        let converter = Converter::new(datagram, peer_addr(), 2_000_000_000);
        let messages = converter.convert();

        assert_eq!(messages.len(), 1);
        let msg = &messages[0];
        assert_eq!(
            msg.src_addr,
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1)
                .octets()
                .to_vec()
        );
        assert_eq!(
            msg.dst_addr,
            Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 2)
                .octets()
                .to_vec()
        );
        assert_eq!(msg.src_port, 5000);
        assert_eq!(msg.dst_port, 53);
        assert_eq!(msg.proto, 17);
        assert_eq!(msg.bytes, 1400);
        assert_eq!(msg.etype, 0x86DD);
        assert_eq!(msg.protocol_name, "UDP");
    }

    // Task 8.3: ExtendedSwitch/Router/Gateway enrichment
    #[test]
    fn test_extended_records_enrichment() {
        let sample = SflowSample::Flow(FlowSample {
            sequence_number: 3,
            source_id_type: 0,
            source_id_index: 1,
            sampling_rate: 512,
            sample_pool: 1024,
            drops: 0,
            input: 1,
            output: 2,
            records: vec![
                FlowRecord::SampledIpv4(SampledIpv4 {
                    length: 1500,
                    protocol: 6,
                    src_ip: Ipv4Addr::new(10, 1, 1, 1),
                    dst_ip: Ipv4Addr::new(10, 2, 2, 2),
                    src_port: 1000,
                    dst_port: 443,
                    tcp_flags: 0x10,
                    tos: 0,
                }),
                FlowRecord::ExtendedSwitch(ExtendedSwitch {
                    src_vlan: 100,
                    src_priority: 0,
                    dst_vlan: 200,
                    dst_priority: 0,
                }),
                FlowRecord::ExtendedRouter(ExtendedRouter {
                    next_hop: AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 254)),
                    src_mask_len: 24,
                    dst_mask_len: 16,
                }),
                FlowRecord::ExtendedGateway(ExtendedGateway {
                    next_hop: AddressType::IPv4(Ipv4Addr::new(10, 0, 0, 253)),
                    as_number: 65001,
                    src_as: 65000,
                    src_peer_as: 65002,
                    as_path_segments: vec![
                        AsPathSegment {
                            segment_type: 2,
                            values: vec![65000, 65001],
                        },
                        AsPathSegment {
                            segment_type: 2,
                            values: vec![65002],
                        },
                    ],
                    communities: vec![100, 200, 300],
                }),
            ],
        });

        let datagram = make_datagram(vec![sample]);
        let converter = Converter::new(datagram, peer_addr(), 3_000_000_000);
        let messages = converter.convert();

        assert_eq!(messages.len(), 1);
        let msg = &messages[0];

        // ExtendedSwitch
        assert_eq!(msg.src_vlan, 100);
        assert_eq!(msg.dst_vlan, 200);

        // ExtendedRouter
        assert_eq!(
            msg.next_hop,
            Ipv4Addr::new(10, 0, 0, 254).octets().to_vec()
        );
        assert_eq!(msg.src_net, 24);
        assert_eq!(msg.dst_net, 16);

        // ExtendedGateway
        assert_eq!(msg.src_as, 65000);
        assert_eq!(msg.dst_as, 65001);
        assert_eq!(
            msg.bgp_next_hop,
            Ipv4Addr::new(10, 0, 0, 253).octets().to_vec()
        );
        assert_eq!(msg.bgp_communities, vec![100, 200, 300]);
        assert_eq!(msg.as_path, vec![65000, 65001, 65002]);
    }

    // Task 8.4: RawPacketHeader-only fallback
    #[test]
    fn test_raw_packet_header_only() {
        let sample = SflowSample::Flow(FlowSample {
            sequence_number: 4,
            source_id_type: 0,
            source_id_index: 1,
            sampling_rate: 512,
            sample_pool: 1024,
            drops: 0,
            input: 1,
            output: 2,
            records: vec![FlowRecord::RawPacketHeader(RawPacketHeader {
                header_protocol: 1, // Ethernet
                frame_length: 1518,
                stripped: 0,
                header_length: 64,
                header: vec![0u8; 64],
            })],
        });

        let datagram = make_datagram(vec![sample]);
        let converter = Converter::new(datagram, peer_addr(), 4_000_000_000);
        let messages = converter.convert();

        assert_eq!(messages.len(), 1);
        let msg = &messages[0];
        assert_eq!(msg.bytes, 1518);
        assert_eq!(msg.etype, 1);
        // No IP-specific fields should be set
        assert!(msg.src_addr.is_empty());
        assert!(msg.dst_addr.is_empty());
    }

    // Task 8.4b: RawPacketHeader with SampledIpv4 — IP record takes precedence
    #[test]
    fn test_raw_packet_header_with_sampled_ipv4() {
        let sample = SflowSample::Flow(FlowSample {
            sequence_number: 5,
            source_id_type: 0,
            source_id_index: 1,
            sampling_rate: 512,
            sample_pool: 1024,
            drops: 0,
            input: 1,
            output: 2,
            records: vec![
                FlowRecord::SampledIpv4(SampledIpv4 {
                    length: 1500,
                    protocol: 6,
                    src_ip: Ipv4Addr::new(10, 1, 1, 1),
                    dst_ip: Ipv4Addr::new(10, 2, 2, 2),
                    src_port: 1000,
                    dst_port: 80,
                    tcp_flags: 0,
                    tos: 0,
                }),
                FlowRecord::RawPacketHeader(RawPacketHeader {
                    header_protocol: 1,
                    frame_length: 1518,
                    stripped: 0,
                    header_length: 64,
                    header: vec![0u8; 64],
                }),
            ],
        });

        let datagram = make_datagram(vec![sample]);
        let converter = Converter::new(datagram, peer_addr(), 5_000_000_000);
        let messages = converter.convert();

        assert_eq!(messages.len(), 1);
        let msg = &messages[0];
        // SampledIpv4 should take precedence for bytes and etype
        assert_eq!(msg.bytes, 1500);
        assert_eq!(msg.etype, 0x0800);
    }

    // Task 8.5: Counter sample skipping
    #[test]
    fn test_counter_samples_skipped() {
        let samples = vec![
            SflowSample::Counter(CounterSample {
                sequence_number: 1,
                source_id_type: 0,
                source_id_index: 1,
                records: vec![],
            }),
            SflowSample::Flow(FlowSample {
                sequence_number: 2,
                source_id_type: 0,
                source_id_index: 1,
                sampling_rate: 512,
                sample_pool: 1024,
                drops: 0,
                input: 1,
                output: 2,
                records: vec![FlowRecord::SampledIpv4(SampledIpv4 {
                    length: 1500,
                    protocol: 6,
                    src_ip: Ipv4Addr::new(10, 1, 1, 1),
                    dst_ip: Ipv4Addr::new(10, 2, 2, 2),
                    src_port: 1000,
                    dst_port: 80,
                    tcp_flags: 0,
                    tos: 0,
                })],
            }),
        ];

        let datagram = make_datagram(samples);
        let converter = Converter::new(datagram, peer_addr(), 6_000_000_000);
        let messages = converter.convert();

        // Only the flow sample should produce a message
        assert_eq!(messages.len(), 1);
        assert_eq!(msg_type(&messages[0]), "SFLOW_5");
    }

    // Task 8.6: Degenerate flow filtering
    #[test]
    fn test_degenerate_flow_filtering() {
        let msg_valid = flowpb::FlowMessage {
            bytes: 100,
            packets: 1,
            ..Default::default()
        };
        let msg_degenerate = flowpb::FlowMessage {
            bytes: 0,
            packets: 0,
            ..Default::default()
        };
        let msg_bytes_only = flowpb::FlowMessage {
            bytes: 100,
            packets: 0,
            ..Default::default()
        };
        let msg_packets_only = flowpb::FlowMessage {
            bytes: 0,
            packets: 1,
            ..Default::default()
        };

        assert!(is_valid_flow(&msg_valid));
        assert!(!is_valid_flow(&msg_degenerate));
        assert!(is_valid_flow(&msg_bytes_only));
        assert!(is_valid_flow(&msg_packets_only));
    }

    #[test]
    fn test_address_type_to_bytes_ipv4() {
        let addr = AddressType::IPv4(Ipv4Addr::new(192, 168, 1, 1));
        assert_eq!(address_type_to_bytes(&addr), vec![192, 168, 1, 1]);
    }

    #[test]
    fn test_address_type_to_bytes_ipv6() {
        let addr = AddressType::IPv6(Ipv6Addr::LOCALHOST);
        let bytes = address_type_to_bytes(&addr);
        assert_eq!(bytes.len(), 16);
        assert_eq!(bytes[15], 1);
    }

    fn msg_type(msg: &flowpb::FlowMessage) -> &'static str {
        match msg.r#type {
            x if x == i32::from(flowpb::flow_message::FlowType::Sflow5) => "SFLOW_5",
            _ => "OTHER",
        }
    }
}
