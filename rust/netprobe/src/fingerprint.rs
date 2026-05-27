#[cfg(feature = "pcap-capture")]
use std::{net::IpAddr, time::SystemTime};

#[cfg(feature = "pcap-capture")]
use anyhow::{Context, Result};
#[cfg(feature = "pcap-capture")]
use huginn_net::{
    huginn_net_tcp::{
        db::MatchQualityType,
        output::{OSQualityMatched, SynAckTCPOutput, SynTCPOutput},
    },
    AnalysisConfig, Database, HuginnNet,
};

#[cfg(feature = "pcap-capture")]
use crate::proto::netprobe::{fingerprint_event, FingerprintEvent, TcpFingerprint};

pub const FINGERPRINT_ENGINE_VERSION: &str = "huginn-net/1.7.3";

#[cfg(feature = "pcap-capture")]
const MAX_CONNECTIONS: usize = 4096;

#[cfg(feature = "pcap-capture")]
pub struct FingerprintEngine {
    analyzer: HuginnNet<'static>,
}

#[cfg(feature = "pcap-capture")]
impl FingerprintEngine {
    pub fn tcp_only() -> Result<Self> {
        let database = Box::leak(Box::new(
            Database::load_default().context("failed to load huginn-net p0f database")?,
        ));
        let config = AnalysisConfig {
            http_enabled: false,
            tcp_enabled: true,
            tls_enabled: false,
            matcher_enabled: true,
        };
        let analyzer = HuginnNet::new(Some(database), MAX_CONNECTIONS, Some(config))
            .context("failed to initialize huginn-net analyzer")?;

        Ok(Self { analyzer })
    }

    pub fn analyze_tcp_packet(
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

#[cfg(all(test, feature = "pcap-capture"))]
mod tests {
    use super::FingerprintEngine;
    use crate::proto::netprobe::fingerprint_event;

    #[test]
    fn emits_tcp_fingerprint_for_ipv4_syn_packet() {
        let mut engine = FingerprintEngine::tcp_only().unwrap();

        let events = engine.analyze_tcp_packet("eth0", 123, ipv4_syn_packet());

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
        let mut engine = FingerprintEngine::tcp_only().unwrap();

        let events = engine.analyze_tcp_packet("eth0", 123, &[0, 1, 2, 3]);

        assert!(events.is_empty());
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
