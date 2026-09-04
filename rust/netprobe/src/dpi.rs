use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub mod dhcp;

use etherparse::{NetHeaders, PacketHeaders, TransportHeader};

use crate::{
    af_xdp_classifier::{canonical_flow_key, transport_protocol},
    fingerprint::{DpiPayloadContext, FingerprintAccumulator},
    proto::netprobe::DpiEvent,
};

#[derive(Clone, Debug)]
pub struct DpiPipeline {
    dissectors: Vec<Dissector>,
}

#[derive(Clone, Copy, Debug)]
struct Dissector {
    id: &'static str,
    protocol: &'static str,
    classify: fn(&Flow, &[u8]) -> Option<f32>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Flow {
    source_ip: IpAddr,
    destination_ip: IpAddr,
    source_port: u16,
    destination_port: u16,
    transport_protocol: &'static str,
}

impl DpiPipeline {
    pub fn phase2() -> Self {
        Self {
            dissectors: vec![
                Dissector {
                    id: "bittorrent_handshake",
                    protocol: "bittorrent",
                    classify: classify_bittorrent,
                },
                Dissector {
                    id: "http2_cleartext_preface",
                    protocol: "http2",
                    classify: classify_http2,
                },
                Dissector {
                    id: "http1_start_line",
                    protocol: "http1",
                    classify: classify_http1,
                },
                Dissector {
                    id: "tls_sni",
                    protocol: "tls",
                    classify: classify_tls,
                },
                Dissector {
                    id: "dns_header",
                    protocol: "dns",
                    classify: classify_dns,
                },
                Dissector {
                    id: "dhcp_options",
                    protocol: "dhcp",
                    classify: classify_dhcp,
                },
                Dissector {
                    id: "dhcpv6_options",
                    protocol: "dhcpv6",
                    classify: classify_dhcpv6,
                },
                Dissector {
                    id: "ssh_banner",
                    protocol: "ssh",
                    classify: classify_ssh,
                },
                Dissector {
                    id: "ftp_control",
                    protocol: "ftp",
                    classify: classify_ftp,
                },
                Dissector {
                    id: "quic_version_negotiation",
                    protocol: "quic",
                    classify: classify_quic,
                },
                Dissector {
                    id: "mqtt_fixed_header",
                    protocol: "mqtt",
                    classify: classify_mqtt,
                },
            ],
        }
    }

    #[allow(dead_code)]
    pub fn analyze_packet(
        &self,
        interface_name: &str,
        observed_at_unix_nano: i64,
        packet: &[u8],
    ) -> Vec<DpiEvent> {
        self.analyze_packet_with_fingerprints(interface_name, observed_at_unix_nano, packet, None)
    }

    pub fn analyze_packet_with_fingerprints(
        &self,
        interface_name: &str,
        observed_at_unix_nano: i64,
        packet: &[u8],
        fingerprint_accumulator: Option<&FingerprintAccumulator>,
    ) -> Vec<DpiEvent> {
        let Some((flow, payload)) = parse_flow(packet) else {
            return Vec::new();
        };
        if let Some(accumulator) = fingerprint_accumulator
            && let Some(flow_key) = flow_key(&flow)
        {
            accumulator.observe_dpi_payload_with_context(
                DpiPayloadContext {
                    flow_key,
                    source_port: flow.source_port,
                    destination_port: flow.destination_port,
                    transport_protocol: flow.transport_protocol,
                },
                payload,
                observed_at_unix_nano,
            );
        }

        self.dissectors
            .iter()
            .filter_map(|dissector| {
                (dissector.classify)(&flow, payload).map(|confidence| (dissector, confidence))
            })
            .max_by(|(_left, left_confidence), (_right, right_confidence)| {
                left_confidence.total_cmp(right_confidence)
            })
            .map(|(dissector, confidence)| {
                vec![event_from_match(
                    interface_name,
                    observed_at_unix_nano,
                    &flow,
                    dissector,
                    confidence,
                )]
            })
            .unwrap_or_default()
    }
}

fn flow_key(flow: &Flow) -> Option<crate::af_xdp_classifier::FlowKey> {
    canonical_flow_key(
        flow.source_ip,
        flow.destination_ip,
        flow.source_port,
        flow.destination_port,
        transport_protocol(flow.transport_protocol)?,
    )
}

fn parse_flow(packet: &[u8]) -> Option<(Flow, &[u8])> {
    let headers = if matches!(packet.first().map(|byte| byte >> 4), Some(4 | 6)) {
        PacketHeaders::from_ip_slice(packet).ok()?
    } else {
        PacketHeaders::from_ethernet_slice(packet).ok()?
    };
    let (source_ip, destination_ip) = ip_pair(headers.net.as_ref()?)?;

    match headers.transport.as_ref()? {
        TransportHeader::Tcp(tcp) => Some((
            Flow {
                source_ip,
                destination_ip,
                source_port: tcp.source_port,
                destination_port: tcp.destination_port,
                transport_protocol: "tcp",
            },
            headers.payload.slice(),
        )),
        TransportHeader::Udp(udp) => Some((
            Flow {
                source_ip,
                destination_ip,
                source_port: udp.source_port,
                destination_port: udp.destination_port,
                transport_protocol: "udp",
            },
            headers.payload.slice(),
        )),
        _ => None,
    }
}

fn ip_pair(headers: &NetHeaders) -> Option<(IpAddr, IpAddr)> {
    match headers {
        NetHeaders::Ipv4(header, _) => Some((
            IpAddr::V4(Ipv4Addr::from(header.source)),
            IpAddr::V4(Ipv4Addr::from(header.destination)),
        )),
        NetHeaders::Ipv6(header, _) => Some((
            IpAddr::V6(Ipv6Addr::from(header.source)),
            IpAddr::V6(Ipv6Addr::from(header.destination)),
        )),
        NetHeaders::Arp(_) => None,
    }
}

fn event_from_match(
    interface_name: &str,
    observed_at_unix_nano: i64,
    flow: &Flow,
    dissector: &Dissector,
    confidence: f32,
) -> DpiEvent {
    DpiEvent {
        source_ip: flow.source_ip.to_string(),
        destination_ip: flow.destination_ip.to_string(),
        source_port: u32::from(flow.source_port),
        destination_port: u32::from(flow.destination_port),
        transport_protocol: flow.transport_protocol.to_string(),
        protocol: dissector.protocol.to_string(),
        confidence,
        observed_at_unix_nano,
        interface_name: interface_name.to_string(),
        profile_id: String::new(),
        dissector_id: dissector.id.to_string(),
    }
}

fn classify_http1(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "tcp" {
        return None;
    }

    const METHODS: [&[u8]; 9] = [
        b"GET ",
        b"POST ",
        b"PUT ",
        b"PATCH ",
        b"DELETE ",
        b"HEAD ",
        b"OPTIONS ",
        b"TRACE ",
        b"CONNECT ",
    ];
    if METHODS.iter().any(|method| payload.starts_with(method))
        || payload.starts_with(b"HTTP/1.0 ")
        || payload.starts_with(b"HTTP/1.1 ")
    {
        return Some(0.95);
    }

    None
}

fn classify_http2(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol == "tcp" && payload.starts_with(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    {
        Some(0.98)
    } else {
        None
    }
}

fn classify_tls(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "tcp" || payload.len() < 5 {
        return None;
    }
    if payload[0] != 0x16 || payload[1] != 0x03 || !(0x00..=0x04).contains(&payload[2]) {
        return None;
    }

    if tls_client_hello_has_sni(payload) {
        Some(0.95)
    } else {
        Some(0.75)
    }
}

fn tls_client_hello_has_sni(payload: &[u8]) -> bool {
    if payload.len() < 9 || payload[5] != 0x01 {
        return false;
    }
    let record_len = u16::from_be_bytes([payload[3], payload[4]]) as usize;
    if payload.len() < 5 + record_len || record_len < 4 {
        return false;
    }
    let handshake_len =
        ((payload[6] as usize) << 16) | ((payload[7] as usize) << 8) | payload[8] as usize;
    let mut offset = 9;
    if handshake_len < 38 || payload.len() < offset + handshake_len {
        return false;
    }

    offset += 2 + 32;
    let Some(session_len) = payload.get(offset).copied().map(usize::from) else {
        return false;
    };
    offset += 1 + session_len;
    if payload.len() < offset + 2 {
        return false;
    }
    let cipher_len = u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
    offset += 2 + cipher_len;
    let Some(compression_len) = payload.get(offset).copied().map(usize::from) else {
        return false;
    };
    offset += 1 + compression_len;
    if payload.len() < offset + 2 {
        return false;
    }
    let extensions_len = u16::from_be_bytes([payload[offset], payload[offset + 1]]) as usize;
    offset += 2;
    let extensions_end = offset.saturating_add(extensions_len).min(payload.len());

    while offset + 4 <= extensions_end {
        let extension_type = u16::from_be_bytes([payload[offset], payload[offset + 1]]);
        let extension_len = u16::from_be_bytes([payload[offset + 2], payload[offset + 3]]) as usize;
        offset += 4;
        if offset + extension_len > extensions_end {
            return false;
        }
        if extension_type == 0 && extension_len > 2 {
            return true;
        }
        offset += extension_len;
    }

    false
}

fn classify_dns(flow: &Flow, payload: &[u8]) -> Option<f32> {
    match flow.transport_protocol {
        "udp" => classify_dns_message(flow, payload),
        "tcp" => {
            if payload.len() < 14 {
                return None;
            }
            let message_len = u16::from_be_bytes([payload[0], payload[1]]) as usize;
            if message_len < 12 || payload.len() < 2 + message_len {
                return None;
            }
            classify_dns_message(flow, &payload[2..2 + message_len])
        }
        _ => None,
    }
}

fn classify_dns_message(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if payload.len() < 12 {
        return None;
    }
    let qdcount = u16::from_be_bytes([payload[4], payload[5]]);
    let ancount = u16::from_be_bytes([payload[6], payload[7]]);
    let nscount = u16::from_be_bytes([payload[8], payload[9]]);
    let arcount = u16::from_be_bytes([payload[10], payload[11]]);
    if qdcount == 0 && ancount == 0 && nscount == 0 && arcount == 0 {
        return None;
    }
    let opcode = (payload[2] >> 3) & 0x0f;
    if opcode > 5 {
        return None;
    }

    Some(if flow.source_port == 53 || flow.destination_port == 53 {
        0.95
    } else {
        0.70
    })
}

fn classify_dhcp(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "udp" {
        return None;
    }
    if !matches!(
        (flow.source_port, flow.destination_port),
        (67, 68) | (68, 67)
    ) {
        return None;
    }

    dhcp::parse_dhcpv4(payload).map(|_| 0.98)
}

fn classify_dhcpv6(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "udp" {
        return None;
    }
    if !matches!(
        (flow.source_port, flow.destination_port),
        (546, 547) | (547, 546)
    ) {
        return None;
    }

    dhcp::parse_dhcpv6(payload).map(|_| 0.98)
}

fn classify_ssh(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol == "tcp" && payload.starts_with(b"SSH-") {
        Some(0.98)
    } else {
        None
    }
}

fn classify_ftp(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "tcp" {
        return None;
    }
    if payload.starts_with(b"USER ")
        || payload.starts_with(b"PASS ")
        || payload.starts_with(b"SYST")
        || payload.starts_with(b"220 ")
        || payload.starts_with(b"331 ")
        || payload.starts_with(b"230 ")
    {
        return Some(0.90);
    }
    None
}

fn classify_quic(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "udp" || payload.len() < 6 || payload[0] & 0x80 == 0 {
        return None;
    }
    let version = u32::from_be_bytes([payload[1], payload[2], payload[3], payload[4]]);
    if version == 0 { Some(0.98) } else { None }
}

fn classify_mqtt(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol != "tcp" || payload.len() < 2 {
        return None;
    }

    let packet_type = payload[0] >> 4;
    if packet_type != 1 {
        return None;
    }

    let (_remaining_len, used) = mqtt_remaining_length(&payload[1..])?;
    let protocol_offset = 1 + used;
    if payload.len() < protocol_offset + 2 {
        return None;
    }
    let protocol_len =
        u16::from_be_bytes([payload[protocol_offset], payload[protocol_offset + 1]]) as usize;
    let protocol_start = protocol_offset + 2;
    let protocol_end = protocol_start + protocol_len;
    if payload.len() < protocol_end {
        return None;
    }

    if &payload[protocol_start..protocol_end] == b"MQTT"
        || &payload[protocol_start..protocol_end] == b"MQIsdp"
    {
        Some(0.95)
    } else {
        None
    }
}

fn mqtt_remaining_length(bytes: &[u8]) -> Option<(usize, usize)> {
    let mut value = 0usize;
    let mut multiplier = 1usize;

    for (idx, byte) in bytes.iter().take(4).enumerate() {
        value = value.saturating_add(usize::from(byte & 0x7f).saturating_mul(multiplier));
        if byte & 0x80 == 0 {
            return Some((value, idx + 1));
        }
        multiplier = multiplier.saturating_mul(128);
    }
    None
}

fn classify_bittorrent(flow: &Flow, payload: &[u8]) -> Option<f32> {
    if flow.transport_protocol == "tcp" && payload.starts_with(b"\x13BitTorrent protocol") {
        Some(0.98)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::DpiPipeline;
    use prost::Message;

    struct DpiCase {
        protocol: &'static str,
        dissector_id: &'static str,
        packet: Vec<u8>,
    }

    #[test]
    fn classifies_phase2_protocols_without_payload_fields() {
        let pipeline = DpiPipeline::phase2();

        for case in dpi_cases() {
            let events = pipeline.analyze_packet("eth0", 123, &case.packet);

            assert_eq!(events.len(), 1, "expected one event for {}", case.protocol);
            let event = &events[0];
            assert_eq!(event.protocol, case.protocol);
            assert_eq!(event.dissector_id, case.dissector_id);
            assert_eq!(event.source_ip, "192.0.2.10");
            assert_eq!(event.destination_ip, "198.51.100.20");
            assert_eq!(event.interface_name, "eth0");
            assert_eq!(event.observed_at_unix_nano, 123);
            assert!(event.confidence > 0.5);
        }
    }

    #[test]
    fn classifies_each_phase2_protocol_from_pcap_fixtures() {
        let pipeline = DpiPipeline::phase2();

        for case in dpi_cases() {
            let written = fixture_pcap(&[case.packet]);
            let packets = read_fixture_pcap(&written);
            assert_eq!(packets.len(), 1, "one packet per fixture");
            let events = pipeline.analyze_packet("eth0", 456, &packets[0]);

            assert_eq!(
                events.len(),
                1,
                "expected one pcap fixture event for {}",
                case.protocol
            );
            let event = &events[0];
            assert_eq!(event.protocol, case.protocol);
            assert_eq!(event.dissector_id, case.dissector_id);
            assert_eq!(event.source_ip, "192.0.2.10");
            assert_eq!(event.destination_ip, "198.51.100.20");
            assert_eq!(event.interface_name, "eth0");
            assert_eq!(event.observed_at_unix_nano, 456);
            assert!(event.confidence > 0.5);
        }
    }

    #[test]
    fn does_not_emit_uri_or_dns_names() {
        let pipeline = DpiPipeline::phase2();
        let events = pipeline.analyze_packet(
            "eth0",
            123,
            &tcp_packet(
                49152,
                80,
                b"GET /top-secret HTTP/1.1\r\nHost: internal\r\n\r\n",
            ),
        );

        let encoded = format!("{:?}", events[0]);
        assert!(!encoded.contains("top-secret"));
        assert!(!encoded.contains("internal"));

        let encoded = events[0].encode_to_vec();
        assert!(
            !encoded
                .windows(b"top-secret".len())
                .any(|w| w == b"top-secret")
        );
        assert!(!encoded.windows(b"internal".len()).any(|w| w == b"internal"));
    }

    #[test]
    fn rejects_port_only_dpi_false_positives() {
        let pipeline = DpiPipeline::phase2();
        let cases = [
            tcp_packet(49152, 80, b"opaque binary protocol"),
            tcp_packet(49152, 21, b"opaque binary protocol"),
            udp_packet(49152, 443, &[0x80, 0, 0, 0, 1, 1]),
            tcp_packet(49152, 1883, b"\x10\x10random MQTT literal"),
        ];

        for packet in cases {
            assert!(pipeline.analyze_packet("eth0", 123, &packet).is_empty());
        }
    }

    #[test]
    fn classifies_dns_over_tcp_length_prefixed_messages() {
        let pipeline = DpiPipeline::phase2();
        let dns = dns_query_header();
        let mut payload = Vec::new();
        payload.extend_from_slice(&(dns.len() as u16).to_be_bytes());
        payload.extend_from_slice(&dns);

        let events = pipeline.analyze_packet("eth0", 123, &tcp_packet(49152, 53, &payload));

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].protocol, "dns");
        assert_eq!(events[0].dissector_id, "dns_header");
    }

    fn tcp_packet(source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
        ipv4_packet(6, source_port, destination_port, payload)
    }

    fn udp_packet(source_port: u16, destination_port: u16, payload: &[u8]) -> Vec<u8> {
        ipv4_packet(17, source_port, destination_port, payload)
    }

    fn dpi_cases() -> Vec<DpiCase> {
        vec![
            DpiCase {
                protocol: "http1",
                dissector_id: "http1_start_line",
                packet: tcp_packet(49152, 80, b"GET /secret HTTP/1.1\r\nHost: example\r\n\r\n"),
            },
            DpiCase {
                protocol: "http2",
                dissector_id: "http2_cleartext_preface",
                packet: tcp_packet(49152, 8080, b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"),
            },
            DpiCase {
                protocol: "tls",
                dissector_id: "tls_sni",
                packet: tcp_packet(49152, 443, &tls_client_hello_with_sni()),
            },
            DpiCase {
                protocol: "dns",
                dissector_id: "dns_header",
                packet: udp_packet(49152, 53, &dns_query_header()),
            },
            DpiCase {
                protocol: "dhcp",
                dissector_id: "dhcp_options",
                packet: udp_packet(68, 67, &dhcp_discover()),
            },
            DpiCase {
                protocol: "dhcpv6",
                dissector_id: "dhcpv6_options",
                packet: udp_packet(546, 547, &dhcpv6_solicit()),
            },
            DpiCase {
                protocol: "ssh",
                dissector_id: "ssh_banner",
                packet: tcp_packet(22, 49152, b"SSH-2.0-OpenSSH_9.9\r\n"),
            },
            DpiCase {
                protocol: "ftp",
                dissector_id: "ftp_control",
                packet: tcp_packet(21, 49152, b"220 ready\r\n"),
            },
            DpiCase {
                protocol: "quic",
                dissector_id: "quic_version_negotiation",
                packet: udp_packet(443, 49152, &[0x80, 0, 0, 0, 0, 1]),
            },
            DpiCase {
                protocol: "mqtt",
                dissector_id: "mqtt_fixed_header",
                packet: tcp_packet(49152, 1883, &mqtt_connect_header()),
            },
            DpiCase {
                protocol: "bittorrent",
                dissector_id: "bittorrent_handshake",
                packet: tcp_packet(
                    49152,
                    6881,
                    b"\x13BitTorrent protocol\x00\x00\x00\x00\x00\x00\x00\x00",
                ),
            },
        ]
    }

    fn ipv4_packet(
        protocol: u8,
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        let transport_len = match protocol {
            6 => 20,
            17 => 8,
            _ => 0,
        };
        let total_len = 20 + transport_len + payload.len();
        let mut packet = Vec::with_capacity(total_len);
        packet.extend_from_slice(&[
            0x45,
            0x00,
            ((total_len >> 8) & 0xff) as u8,
            (total_len & 0xff) as u8,
            0x12,
            0x34,
            0x40,
            0x00,
            0x40,
            protocol,
            0x00,
            0x00,
            192,
            0,
            2,
            10,
            198,
            51,
            100,
            20,
        ]);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());

        match protocol {
            6 => {
                packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
                packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
                packet.extend_from_slice(&[0x50, 0x18]);
                packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
                packet.extend_from_slice(&0u16.to_be_bytes());
                packet.extend_from_slice(&0u16.to_be_bytes());
            }
            17 => {
                let udp_len = (8 + payload.len()) as u16;
                packet.extend_from_slice(&udp_len.to_be_bytes());
                packet.extend_from_slice(&0u16.to_be_bytes());
            }
            _ => {}
        }
        packet.extend_from_slice(payload);
        packet
    }

    fn tls_client_hello_with_sni() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0);
        body.extend_from_slice(&2u16.to_be_bytes());
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(1);
        body.push(0);

        let mut sni = Vec::new();
        sni.extend_from_slice(&16u16.to_be_bytes());
        sni.push(0);
        sni.extend_from_slice(&13u16.to_be_bytes());
        sni.extend_from_slice(b"internal.test");
        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0u16.to_be_bytes());
        extensions.extend_from_slice(&(sni.len() as u16).to_be_bytes());
        extensions.extend_from_slice(&sni);
        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x01,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&(handshake.len() as u16).to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn dns_query_header() -> Vec<u8> {
        vec![0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }

    fn mqtt_connect_header() -> Vec<u8> {
        let mut packet = vec![0x10, 0x0c, 0x00, 0x04];
        packet.extend_from_slice(b"MQTT");
        packet.extend_from_slice(&[0x04, 0x02, 0x00, 0x3c]);
        packet
    }

    fn dhcp_discover() -> Vec<u8> {
        let mut packet = vec![0u8; 240];
        packet[0] = 1;
        packet[1] = 1;
        packet[2] = 6;
        packet[236..240].copy_from_slice(&[99, 130, 83, 99]);
        packet.extend_from_slice(&[53, 1, 1]);
        packet.extend_from_slice(&[55, 4, 1, 3, 6, 15]);
        packet.extend_from_slice(&[60, 19]);
        packet.extend_from_slice(b"secret-vendor-class");
        packet.push(255);
        packet
    }

    fn dhcpv6_solicit() -> Vec<u8> {
        let mut packet = vec![1, 0xaa, 0xbb, 0xcc];
        packet.extend_from_slice(&6u16.to_be_bytes());
        packet.extend_from_slice(&4u16.to_be_bytes());
        packet.extend_from_slice(&23u16.to_be_bytes());
        packet.extend_from_slice(&24u16.to_be_bytes());
        packet.extend_from_slice(&16u16.to_be_bytes());
        packet.extend_from_slice(&13u16.to_be_bytes());
        packet.extend_from_slice(b"secret-vendor");
        packet
    }

    fn fixture_pcap(packets: &[Vec<u8>]) -> Vec<u8> {
        let mut pcap = Vec::new();
        pcap.extend_from_slice(&0xa1b2c3d4u32.to_le_bytes());
        pcap.extend_from_slice(&2u16.to_le_bytes());
        pcap.extend_from_slice(&4u16.to_le_bytes());
        pcap.extend_from_slice(&0i32.to_le_bytes());
        pcap.extend_from_slice(&0u32.to_le_bytes());
        pcap.extend_from_slice(&65_535u32.to_le_bytes());
        pcap.extend_from_slice(&101u32.to_le_bytes());

        for packet in packets {
            pcap.extend_from_slice(&1u32.to_le_bytes());
            pcap.extend_from_slice(&0u32.to_le_bytes());
            pcap.extend_from_slice(&(packet.len() as u32).to_le_bytes());
            pcap.extend_from_slice(&(packet.len() as u32).to_le_bytes());
            pcap.extend_from_slice(packet);
        }

        pcap
    }

    /// Reads back what `fixture_pcap` writes.
    ///
    /// Symmetric with the writer above rather than a libpcap call: the pcap
    /// file format here is a 24-byte global header followed by a 16-byte header
    /// per packet, so parsing it costs less than carrying a C dependency that
    /// exists only for these fixtures.
    fn read_fixture_pcap(bytes: &[u8]) -> Vec<Vec<u8>> {
        assert!(bytes.len() >= 24, "pcap fixture is shorter than its header");
        assert_eq!(
            u32::from_le_bytes(bytes[0..4].try_into().unwrap()),
            0xa1b2_c3d4,
            "fixture is not a little-endian pcap"
        );

        let mut packets = Vec::new();
        let mut offset = 24;
        while offset + 16 <= bytes.len() {
            let incl_len =
                u32::from_le_bytes(bytes[offset + 8..offset + 12].try_into().unwrap()) as usize;
            let start = offset + 16;
            let end = start + incl_len;
            assert!(end <= bytes.len(), "pcap record runs past the buffer");
            packets.push(bytes[start..end].to_vec());
            offset = end;
        }
        packets
    }
}
