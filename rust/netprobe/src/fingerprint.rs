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
    AnalysisConfig, Database, HuginnNet,
};

#[cfg(feature = "pcap-capture")]
use crate::proto::netprobe::{
    fingerprint_event, FingerprintEvent, HttpFingerprint, TcpFingerprint,
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
            tls_enabled: false,
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

#[cfg(all(test, feature = "pcap-capture"))]
mod tests {
    use super::{header_value, FingerprintEngine};
    use crate::proto::netprobe::fingerprint_event;
    use huginn_net::huginn_net_http::http_common::{HeaderSource, HttpHeader};

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

    fn ipv4_syn_packet() -> &'static [u8] {
        &[
            0x45, 0x00, 0x00, 0x3c, 0x12, 0x34, 0x40, 0x00, 0x40, 0x06, 0x00, 0x00, 0xc0, 0x00,
            0x02, 0x0a, 0xc6, 0x33, 0x64, 0x14, 0xd4, 0x31, 0x01, 0xbb, 0x01, 0x02, 0x03, 0x04,
            0x00, 0x00, 0x00, 0x00, 0xa0, 0x02, 0xfa, 0xf0, 0x00, 0x00, 0x00, 0x00, 0x02, 0x04,
            0x05, 0xb4, 0x04, 0x02, 0x08, 0x0a, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x01, 0x03, 0x03, 0x07,
        ]
    }
}
