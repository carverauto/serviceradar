#[cfg(feature = "pcap-capture")]
use std::{net::IpAddr, time::SystemTime};

#[cfg(feature = "pcap-capture")]
use anyhow::{Context, Result};
#[cfg(feature = "pcap-capture")]
use huginn_net::{
    huginn_net_http::{
        http_common::HttpHeader,
        output::{HttpRequestOutput, HttpResponseOutput},
    },
    huginn_net_tcp::{
        db::MatchQualityType,
        output::{OSQualityMatched, SynAckTCPOutput, SynTCPOutput},
    },
    huginn_net_tls::output::TlsClientOutput,
    AnalysisConfig, Database, HuginnNet,
};

#[cfg(feature = "pcap-capture")]
use crate::proto::netprobe::{
    fingerprint_event, FingerprintEvent, HttpFingerprint, TcpFingerprint, TlsFingerprint,
};

pub const FINGERPRINT_ENGINE_VERSION: &str = "huginn-net/1.7.3";

#[cfg(feature = "pcap-capture")]
const MAX_CONNECTIONS: usize = 4096;

#[cfg(feature = "pcap-capture")]
pub struct FingerprintEngine {
    analyzer: HuginnNet<'static>,
}

#[cfg(feature = "pcap-capture")]
impl FingerprintEngine {
    pub fn phase1() -> Result<Self> {
        let database = Box::leak(Box::new(
            Database::load_default().context("failed to load huginn-net p0f database")?,
        ));
        let config = AnalysisConfig {
            http_enabled: true,
            tcp_enabled: true,
            tls_enabled: true,
            matcher_enabled: true,
        };
        let analyzer = HuginnNet::new(Some(database), MAX_CONNECTIONS, Some(config))
            .context("failed to initialize huginn-net analyzer")?;

        Ok(Self { analyzer })
    }

    pub fn analyze_packet(
        &mut self,
        interface_name: &str,
        observed_at_unix_nano: i64,
        packet: &[u8],
    ) -> Vec<FingerprintEvent> {
        let result = self.analyzer.analyze_tcp(packet);
        let mut events = Vec::new();

        if let Some(syn) = result.tcp_syn {
            events.push(event_from_syn(interface_name, observed_at_unix_nano, syn));
        }

        if let Some(syn_ack) = result.tcp_syn_ack {
            events.push(event_from_syn_ack(
                interface_name,
                observed_at_unix_nano,
                syn_ack,
            ));
        }

        if let Some(request) = result.http_request {
            if let Some(event) =
                event_from_http_request(interface_name, observed_at_unix_nano, request)
            {
                events.push(event);
            }
        }

        if let Some(response) = result.http_response {
            if let Some(event) =
                event_from_http_response(interface_name, observed_at_unix_nano, response)
            {
                events.push(event);
            }
        }

        if let Some(tls_client) = result.tls_client {
            events.push(event_from_tls_client(
                interface_name,
                observed_at_unix_nano,
                tls_client,
            ));
        }

        if let Some(tls_server) = crate::tls_server::fingerprint(packet) {
            events.push(event_from_tls_server(
                interface_name,
                observed_at_unix_nano,
                tls_server,
            ));
        }

        events
    }
}

#[cfg(feature = "pcap-capture")]
pub fn now_unix_nano() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as i64)
        .unwrap_or_default()
}

#[cfg(feature = "pcap-capture")]
fn event_from_syn(
    interface_name: &str,
    observed_at_unix_nano: i64,
    syn: SynTCPOutput,
) -> FingerprintEvent {
    tcp_event(
        syn.source.ip,
        interface_name,
        observed_at_unix_nano,
        syn.sig.matching.to_string(),
        &syn.os_matched,
    )
}

#[cfg(feature = "pcap-capture")]
fn event_from_syn_ack(
    interface_name: &str,
    observed_at_unix_nano: i64,
    syn_ack: SynAckTCPOutput,
) -> FingerprintEvent {
    tcp_event(
        syn_ack.source.ip,
        interface_name,
        observed_at_unix_nano,
        syn_ack.sig.matching.to_string(),
        &syn_ack.os_matched,
    )
}

#[cfg(feature = "pcap-capture")]
fn tcp_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    signature: String,
    os_matched: &OSQualityMatched,
) -> FingerprintEvent {
    let confidence = match os_matched.quality {
        MatchQualityType::Matched(score) => score,
        MatchQualityType::NotMatched | MatchQualityType::Disabled => 0.0,
    };
    let (os_family, os_name) = os_matched
        .os
        .as_ref()
        .map(|os| {
            (
                os.family.clone().unwrap_or_default(),
                os.variant
                    .as_ref()
                    .map(|variant| format!("{} {variant}", os.name))
                    .unwrap_or_else(|| os.name.clone()),
            )
        })
        .unwrap_or_default();

    FingerprintEvent {
        ip: ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Tcp(TcpFingerprint {
            signature,
            os_family,
            os_name,
            confidence,
        })),
    }
}

#[cfg(feature = "pcap-capture")]
fn event_from_http_request(
    interface_name: &str,
    observed_at_unix_nano: i64,
    request: HttpRequestOutput,
) -> Option<FingerprintEvent> {
    let user_agent = request.sig.user_agent.unwrap_or_default();
    let accept_language = header_value(&request.sig.headers, "accept-language")
        .or(request.lang)
        .unwrap_or_default();

    if user_agent.is_empty() && accept_language.is_empty() {
        return None;
    }

    Some(http_event(
        request.source.ip,
        interface_name,
        observed_at_unix_nano,
        HttpFingerprint {
            user_agent,
            server: String::new(),
            accept_language,
        },
    ))
}

#[cfg(feature = "pcap-capture")]
fn event_from_http_response(
    interface_name: &str,
    observed_at_unix_nano: i64,
    response: HttpResponseOutput,
) -> Option<FingerprintEvent> {
    let server = header_value(&response.sig.headers, "server").unwrap_or_default();
    if server.is_empty() {
        return None;
    }

    Some(http_event(
        response.source.ip,
        interface_name,
        observed_at_unix_nano,
        HttpFingerprint {
            user_agent: String::new(),
            server,
            accept_language: String::new(),
        },
    ))
}

#[cfg(feature = "pcap-capture")]
fn http_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    fingerprint: HttpFingerprint,
) -> FingerprintEvent {
    FingerprintEvent {
        ip: ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Http(fingerprint)),
    }
}

#[cfg(feature = "pcap-capture")]
fn header_value(headers: &[HttpHeader], name: &str) -> Option<String> {
    headers
        .iter()
        .find(|header| header.name.eq_ignore_ascii_case(name))
        .and_then(|header| header.value.clone())
}

#[cfg(feature = "pcap-capture")]
fn event_from_tls_client(
    interface_name: &str,
    observed_at_unix_nano: i64,
    tls_client: TlsClientOutput,
) -> FingerprintEvent {
    FingerprintEvent {
        ip: tls_client.source.ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Tls(TlsFingerprint {
            ja4: tls_client.sig.ja4.full.value().to_string(),
            ja4s: String::new(),
            sni_redacted: redact_sni_presence(tls_client.sig.sni.as_deref()).to_string(),
        })),
    }
}

#[cfg(feature = "pcap-capture")]
fn event_from_tls_server(
    interface_name: &str,
    observed_at_unix_nano: i64,
    tls_server: crate::tls_server::TlsServerFingerprint,
) -> FingerprintEvent {
    FingerprintEvent {
        ip: tls_server.source_ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Tls(TlsFingerprint {
            ja4: String::new(),
            ja4s: tls_server.ja4s,
            sni_redacted: String::new(),
        })),
    }
}

#[cfg(feature = "pcap-capture")]
fn redact_sni_presence(sni: Option<&str>) -> &'static str {
    match sni {
        Some("") | None => "",
        Some(_) => "<present>",
    }
}

#[cfg(all(test, feature = "pcap-capture"))]
mod tests {
    use super::{header_value, redact_sni_presence, FingerprintEngine};
    use crate::proto::netprobe::fingerprint_event;
    use huginn_net::huginn_net_http::http_common::{HeaderSource, HttpHeader};
    use std::io::Write;

    #[test]
    fn emits_tcp_fingerprint_for_ipv4_syn_packet() {
        let mut engine = FingerprintEngine::phase1().unwrap();

        let events = engine.analyze_packet("eth0", 123, ipv4_syn_packet());

        assert_eq!(events.len(), 1);
        assert_eq!(events[0].ip, "192.0.2.10");
        assert_eq!(events[0].interface_name, "eth0");
        assert_eq!(events[0].observed_at_unix_nano, 123);
        let Some(fingerprint_event::Evidence::Tcp(tcp)) = &events[0].evidence else {
            panic!("expected TCP fingerprint event");
        };
        assert!(!tcp.signature.is_empty());
    }

    #[test]
    fn ignores_non_tcp_packets() {
        let mut engine = FingerprintEngine::phase1().unwrap();

        let events = engine.analyze_packet("eth0", 123, &[0, 1, 2, 3]);

        assert!(events.is_empty());
    }

    #[test]
    fn finds_http_header_values_case_insensitively() {
        let headers = vec![HttpHeader::new(
            "User-Agent",
            Some("ServiceRadar Test"),
            0,
            HeaderSource::Http1Line,
        )];

        assert_eq!(
            header_value(&headers, "user-agent"),
            Some("ServiceRadar Test".to_string())
        );
    }

    #[test]
    fn redacts_sni_values_to_presence_only() {
        assert_eq!(redact_sni_presence(Some("example.com")), "<present>");
        assert_eq!(redact_sni_presence(Some("")), "");
        assert_eq!(redact_sni_presence(None), "");
    }

    #[test]
    fn emits_fixture_pcap_event_variants() {
        let fixture = fixture_pcap(&[
            tcp_syn_packet([192, 0, 2, 21], [198, 51, 100, 40], 49_152, 80),
            http_request_packet(),
            http_response_packet(),
            tls_client_hello_packet(),
            tls_server_hello_packet(),
        ]);
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(&fixture).unwrap();

        let mut capture = pcap::Capture::from_file(file.path()).unwrap();
        let mut engine = FingerprintEngine::phase1().unwrap();
        let mut events = Vec::new();

        while let Ok(packet) = capture.next_packet() {
            events.extend(engine.analyze_packet("eth0", 456, packet.data));
        }

        let http_request = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::Http(http))
                if http.user_agent == "ServiceRadar Test" =>
            {
                Some((event, http))
            }
            _ => None,
        });
        let (event, http) = http_request.expect("expected HTTP request fingerprint event");
        assert_eq!(event.ip, "192.0.2.21");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(event.observed_at_unix_nano, 456);
        assert_eq!(http.accept_language, "en-US,en;q=0.9");

        let http_response = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::Http(http))
                if http.server == "ServiceRadar Fixture" =>
            {
                Some((event, http))
            }
            _ => None,
        });
        let (event, http) = http_response.expect("expected HTTP response fingerprint event");
        assert_eq!(event.ip, "198.51.100.40");
        assert_eq!(http.user_agent, "");

        let tls_client = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::Tls(tls)) if !tls.ja4.is_empty() => {
                Some((event, tls))
            }
            _ => None,
        });
        let (event, tls) = tls_client.expect("expected TLS ClientHello fingerprint event");
        assert_eq!(event.ip, "192.0.2.22");
        assert!(tls.ja4.starts_with("t12i"));
        assert_eq!(tls.ja4s, "");
        assert_eq!(tls.sni_redacted, "");

        let tls_server = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::Tls(tls)) if !tls.ja4s.is_empty() => {
                Some((event, tls))
            }
            _ => None,
        });
        let (event, tls) = tls_server.expect("expected TLS ServerHello fingerprint event");
        assert_eq!(event.ip, "198.51.100.40");
        assert_eq!(tls.ja4, "");
        assert_eq!(tls.ja4s, "t1302h2_1301_b9a491fefe05");
        assert_eq!(tls.sni_redacted, "");
    }

    fn ipv4_syn_packet() -> &'static [u8] {
        &[
            0x45, 0x00, 0x00, 0x3c, 0x12, 0x34, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xc0, 0x00,
            0x02, 0x0a, 0xc6, 0x33, 0x64, 0x14, 0xd4, 0x31, 0x01, 0xbb, 0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x00, 0xa0, 0x02, 0xfa, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x02, 0x04,
            0x05, 0xb4, 0x04, 0x02, 0x08, 0x0a, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x03, 0x03, 0x07,
        ]
    }

    fn fixture_pcap(packets: &[Vec<u8>]) -> Vec<u8> {
        let mut pcap = Vec::new();
        pcap.extend_from_slice(&0xa1b2c3d4u32.to_le_bytes());
        pcap.extend_from_slice(&2u16.to_le_bytes());
        pcap.extend_from_slice(&4u16.to_le_bytes());
        pcap.extend_from_slice(&0i32.to_le_bytes());
        pcap.extend_from_slice(&0u32.to_le_bytes());
        pcap.extend_from_slice(&65_535u32.to_le_bytes());
        pcap.extend_from_slice(&101u32.to_le_bytes()); // DLT_RAW, packet data starts at IP header.

        for packet in packets {
            pcap.extend_from_slice(&1u32.to_le_bytes());
            pcap.extend_from_slice(&0u32.to_le_bytes());
            pcap.extend_from_slice(&(packet.len() as u32).to_le_bytes());
            pcap.extend_from_slice(&(packet.len() as u32).to_le_bytes());
            pcap.extend_from_slice(packet);
        }

        pcap
    }

    fn http_request_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [192, 0, 2, 21],
            [198, 51, 100, 40],
            49_152,
            80,
            b"GET / HTTP/1.1\r\nHost: example.com\r\nUser-Agent: ServiceRadar Test\r\nAccept-Language: en-US,en;q=0.9\r\n\r\n",
        )
    }

    fn http_response_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [198, 51, 100, 40],
            [192, 0, 2, 21],
            80,
            49_152,
            b"HTTP/1.1 200 OK\r\nServer: ServiceRadar Fixture\r\nContent-Length: 0\r\n\r\n",
        )
    }

    fn tls_client_hello_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [192, 0, 2, 22],
            [198, 51, 100, 40],
            49_153,
            443,
            &tls_client_hello_payload(),
        )
    }

    fn tls_client_hello_payload() -> Vec<u8> {
        let cipher_suites = [0x1301u16, 0x1302u16];
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&((cipher_suites.len() * 2) as u16).to_be_bytes());
        for suite in cipher_suites {
            body.extend_from_slice(&suite.to_be_bytes());
        }
        body.push(0x01);
        body.push(0x00);
        body.extend_from_slice(&0u16.to_be_bytes());

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x01,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn tls_server_hello_packet() -> Vec<u8> {
        ipv4_tcp_packet(
            [198, 51, 100, 40],
            [192, 0, 2, 22],
            443,
            49_153,
            &tls_server_hello_payload(),
        )
    }

    fn tls_server_hello_payload() -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&[0x03, 0x03]);
        body.extend_from_slice(&[0u8; 32]);
        body.push(0x00);
        body.extend_from_slice(&0x1301u16.to_be_bytes());
        body.push(0x00);

        let mut extensions = Vec::new();
        extensions.extend_from_slice(&0x002bu16.to_be_bytes());
        extensions.extend_from_slice(&2u16.to_be_bytes());
        extensions.extend_from_slice(&0x0304u16.to_be_bytes());
        extensions.extend_from_slice(&0x0010u16.to_be_bytes());
        extensions.extend_from_slice(&5u16.to_be_bytes());
        extensions.extend_from_slice(&3u16.to_be_bytes());
        extensions.push(2);
        extensions.extend_from_slice(b"h2");

        body.extend_from_slice(&(extensions.len() as u16).to_be_bytes());
        body.extend_from_slice(&extensions);

        let body_len = body.len() as u32;
        let mut handshake = vec![
            0x02,
            ((body_len >> 16) & 0xff) as u8,
            ((body_len >> 8) & 0xff) as u8,
            (body_len & 0xff) as u8,
        ];
        handshake.extend_from_slice(&body);

        let record_len = handshake.len() as u16;
        let mut record = vec![0x16, 0x03, 0x03];
        record.extend_from_slice(&record_len.to_be_bytes());
        record.extend_from_slice(&handshake);
        record
    }

    fn ipv4_tcp_packet(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        payload: &[u8],
    ) -> Vec<u8> {
        ipv4_tcp_packet_with_flags(
            source_ip,
            destination_ip,
            source_port,
            destination_port,
            0x18,
            payload,
        )
    }

    fn tcp_syn_packet(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
    ) -> Vec<u8> {
        ipv4_tcp_packet_with_flags(
            source_ip,
            destination_ip,
            source_port,
            destination_port,
            0x02,
            &[],
        )
    }

    fn ipv4_tcp_packet_with_flags(
        source_ip: [u8; 4],
        destination_ip: [u8; 4],
        source_port: u16,
        destination_port: u16,
        flags: u8,
        payload: &[u8],
    ) -> Vec<u8> {
        let total_len = 20 + 20 + payload.len();
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
            0x06,
            0x00,
            0x00,
        ]);
        packet.extend_from_slice(&source_ip);
        packet.extend_from_slice(&destination_ip);
        packet.extend_from_slice(&source_port.to_be_bytes());
        packet.extend_from_slice(&destination_port.to_be_bytes());
        packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
        packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]);
        packet.extend_from_slice(&[0x50, flags]);
        packet.extend_from_slice(&0xfa_f0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(&0u16.to_be_bytes());
        packet.extend_from_slice(payload);
        packet
    }
}
