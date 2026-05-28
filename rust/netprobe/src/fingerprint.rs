use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

#[cfg(feature = "pcap-capture")]
use std::time::SystemTime;

#[cfg(feature = "pcap-capture")]
use anyhow::Context;
#[cfg(any(feature = "pcap-capture", target_os = "linux"))]
use anyhow::Result;
#[cfg(feature = "pcap-capture")]
use etherparse::{NetHeaders, PacketHeaders, TransportHeader};
#[cfg(feature = "pcap-capture")]
use huginn_net::{
    huginn_net_http::{
        http_common::HttpHeader,
        output::{HttpRequestOutput, HttpResponseOutput},
    },
    huginn_net_tcp::{
        db::{
            tcp::{IpVersion, PayloadSize, Quirk, TcpOption, Ttl, WindowSize},
            MatchQualityType,
        },
        observable::ObservableTcp,
        output::{OSQualityMatched, SynAckTCPOutput, SynTCPOutput},
    },
    huginn_net_tls::output::TlsClientOutput,
    AnalysisConfig, Database, HuginnNet,
};

#[cfg(feature = "pcap-capture")]
use crate::hassh;
use crate::proto::netprobe::{
    fingerprint_event, FingerprintDisagreement, FingerprintEvent, LicenseCleanFingerprint,
    OsMatch as ProtoOsMatch, P0fFingerprintMatch,
};
#[cfg(feature = "pcap-capture")]
use crate::proto::netprobe::{HttpFingerprint, TcpFingerprint, TlsFingerprint};
use crate::{
    af_xdp_classifier::FlowKey,
    os_matcher::{self, FingerprintSignal, OsMatchInput, P0fObservation, SignalDisagreement},
    p0f_matcher::{P0fMatch, P0fMatcher},
};
#[cfg(target_os = "linux")]
use crate::{metrics::Metrics, runtime_config::FingerprintEventGate};

pub const FINGERPRINT_ENGINE_VERSION: &str = "huginn-net/1.7.3";
#[allow(dead_code)]
const EVENT_VERSION: u16 = 1;
#[allow(dead_code)]
const AF_INET: u16 = 2;
#[allow(dead_code)]
const AF_INET6: u16 = 10;
#[allow(dead_code)]
const FLOW_ENDPOINT_A: u8 = 1;
#[allow(dead_code)]
const FLOW_ENDPOINT_B: u8 = 2;
#[allow(dead_code)]
const P0F_SIGNATURE_MAX_LEN: usize = 96;
#[allow(dead_code)]
const P0F_RING_RECORD_LEN: usize = 160;
#[cfg(target_os = "linux")]
#[allow(dead_code)]
const P0F_SIGNATURES_MAP: &str = "p0f_signatures";

#[cfg(feature = "pcap-capture")]
const MAX_CONNECTIONS: usize = 4096;

#[cfg(feature = "pcap-capture")]
pub struct FingerprintEngine {
    analyzer: HuginnNet<'static>,
    p0f_matcher: P0fMatcher,
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
        let p0f_matcher = P0fMatcher::bundled().context("failed to initialize p0f matcher")?;

        Ok(Self {
            analyzer,
            p0f_matcher,
        })
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
            let ip = syn.source.ip;
            let p0f_signature = syn.sig.matching.to_string();
            events.push(event_from_syn(interface_name, observed_at_unix_nano, syn));
            if let Some(event) = self.license_clean_event_from_p0f(
                ip,
                interface_name,
                observed_at_unix_nano,
                p0f_signature,
            ) {
                events.push(event);
            }
        }

        if let Some(syn_ack) = result.tcp_syn_ack {
            let ip = syn_ack.source.ip;
            let p0f_signature = syn_ack.sig.matching.to_string();
            events.push(event_from_syn_ack(
                interface_name,
                observed_at_unix_nano,
                syn_ack,
            ));
            if let Some(event) = self.license_clean_event_from_p0f(
                ip,
                interface_name,
                observed_at_unix_nano,
                p0f_signature,
            ) {
                events.push(event);
            }
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

        events.extend(license_clean_events_from_payload(
            interface_name,
            observed_at_unix_nano,
            packet,
        ));

        events
    }

    fn license_clean_event_from_p0f(
        &self,
        ip: IpAddr,
        interface_name: &str,
        observed_at_unix_nano: i64,
        p0f_signature: String,
    ) -> Option<FingerprintEvent> {
        let matched = match self.p0f_matcher.match_signature(&p0f_signature) {
            Ok(Some(matched)) => matched,
            Ok(None) => return None,
            Err(error) => {
                log::warn!("failed to match p0f signature {p0f_signature:?}: {error}");
                return None;
            }
        };

        Some(license_clean_p0f_event(
            ip,
            interface_name,
            observed_at_unix_nano,
            p0f_signature,
            matched,
        ))
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
        &syn.sig,
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
        &syn_ack.sig,
        &syn_ack.os_matched,
    )
}

#[cfg(feature = "pcap-capture")]
fn tcp_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    signature: String,
    sig: &ObservableTcp,
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
            ttl: ttl_value(&sig.matching.ittl) as u32,
            window_size: window_size_value(&sig.matching.wsize),
            mss: sig.matching.mss.unwrap_or_default() as u32,
            options_layout: sig.matching.olayout.iter().map(tcp_option_value).collect(),
            quirks: sig.matching.quirks.iter().map(quirk_value).collect(),
            ip_version: ip_version_value(sig.matching.version).to_string(),
            window_scale: sig.matching.wscale.unwrap_or_default() as u32,
            payload_class: payload_class_value(sig.matching.pclass).to_string(),
        })),
    }
}

#[cfg(feature = "pcap-capture")]
fn ttl_value(ttl: &Ttl) -> u8 {
    match ttl {
        Ttl::Value(value) | Ttl::Guess(value) | Ttl::Bad(value) => *value,
        Ttl::Distance(observed, distance) => observed.saturating_add(*distance),
    }
}

#[cfg(feature = "pcap-capture")]
fn window_size_value(window: &WindowSize) -> String {
    match window {
        WindowSize::Mss(value) => format!("mss:{value}"),
        WindowSize::Mtu(value) => format!("mtu:{value}"),
        WindowSize::Value(value) => value.to_string(),
        WindowSize::Mod(value) => format!("mod:{value}"),
        WindowSize::Any => "any".to_string(),
    }
}

#[cfg(feature = "pcap-capture")]
fn ip_version_value(version: IpVersion) -> &'static str {
    match version {
        IpVersion::V4 => "4",
        IpVersion::V6 => "6",
        IpVersion::Any => "any",
    }
}

#[cfg(feature = "pcap-capture")]
fn payload_class_value(payload: PayloadSize) -> &'static str {
    match payload {
        PayloadSize::Zero => "zero",
        PayloadSize::NonZero => "nonzero",
        PayloadSize::Any => "any",
    }
}

#[cfg(feature = "pcap-capture")]
fn tcp_option_value(option: &TcpOption) -> String {
    match option {
        TcpOption::Eol(padding) => format!("eol:{padding}"),
        TcpOption::Nop => "nop".to_string(),
        TcpOption::Mss => "mss".to_string(),
        TcpOption::Ws => "ws".to_string(),
        TcpOption::Sok => "sok".to_string(),
        TcpOption::Sack => "sack".to_string(),
        TcpOption::TS => "ts".to_string(),
        TcpOption::Unknown(value) => format!("unknown:{value}"),
    }
}

#[cfg(feature = "pcap-capture")]
fn quirk_value(quirk: &Quirk) -> String {
    match quirk {
        Quirk::Df => "df",
        Quirk::NonZeroID => "id+",
        Quirk::ZeroID => "id-",
        Quirk::Ecn => "ecn",
        Quirk::MustBeZero => "0+",
        Quirk::FlowID => "flow",
        Quirk::SeqNumZero => "seq-",
        Quirk::AckNumNonZero => "ack+",
        Quirk::AckNumZero => "ack-",
        Quirk::NonZeroURG => "uptr+",
        Quirk::Urg => "urgf+",
        Quirk::Push => "pushf+",
        Quirk::OwnTimestampZero => "ts1-",
        Quirk::PeerTimestampNonZero => "ts2+",
        Quirk::TrailinigNonZero => "opt+",
        Quirk::ExcessiveWindowScaling => "exws",
        Quirk::OptBad => "bad",
    }
    .to_string()
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

#[allow(dead_code)]
fn license_clean_p0f_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    p0f_signature: String,
    matched: P0fMatch,
) -> FingerprintEvent {
    let os_match = os_matcher::evaluate(OsMatchInput {
        p0f: P0fObservation {
            signature: p0f_signature,
            matched,
        },
        ja4: None,
        hassh: None,
    });

    license_clean_event(
        ip,
        interface_name,
        observed_at_unix_nano,
        LicenseCleanFingerprint {
            p0f_signature: os_match.p0f_signature.clone(),
            p0f_match: Some(P0fFingerprintMatch {
                label: os_match.p0f_label.raw.clone(),
                name: os_match.p0f_label.name.clone(),
                version_flavor: os_match.p0f_label.flavor.clone().unwrap_or_default(),
                os_family: os_match.os_family.clone(),
            }),
            os_match: Some(proto_os_match(&os_match)),
            agreement_count: os_match.agreement_count,
            ..Default::default()
        },
    )
}

#[allow(dead_code)]
#[derive(Clone, Debug)]
pub struct P0fRingRecord {
    pub version: u16,
    pub source_endpoint: u8,
    pub flow_key: FlowKey,
    pub observed_ns: u64,
    pub p0f_signature: String,
}

#[allow(dead_code)]
pub struct P0fSignatureEngine {
    matcher: P0fMatcher,
}

#[allow(dead_code)]
impl P0fSignatureEngine {
    pub fn bundled() -> anyhow::Result<Self> {
        Ok(Self {
            matcher: P0fMatcher::bundled()?,
        })
    }

    pub fn event_from_ring_record(
        &self,
        interface_name: &str,
        record: &P0fRingRecord,
    ) -> Option<FingerprintEvent> {
        if record.version != EVENT_VERSION {
            log::warn!(
                "dropping unsupported p0f signature record version {}",
                record.version
            );
            return None;
        }

        let matched = match self.matcher.match_signature(&record.p0f_signature) {
            Ok(Some(matched)) => matched,
            Ok(None) => return None,
            Err(error) => {
                log::warn!(
                    "failed to match p0f signature {:?}: {error}",
                    record.p0f_signature
                );
                return None;
            }
        };
        let source_ip = source_ip_from_flow_key(&record.flow_key, record.source_endpoint)?;

        Some(license_clean_p0f_event(
            source_ip,
            interface_name,
            record.observed_ns.min(i64::MAX as u64) as i64,
            record.p0f_signature.clone(),
            matched,
        ))
    }

    pub fn event_from_ring_bytes(
        &self,
        interface_name: &str,
        bytes: &[u8],
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record(interface_name, &parse_p0f_ring_record(bytes)?)
    }
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
pub struct P0fSignatureRing<'a> {
    interface_name: String,
    engine: P0fSignatureEngine,
    ring: aya::maps::RingBuf<&'a mut aya::maps::MapData>,
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
impl<'a> P0fSignatureRing<'a> {
    pub fn from_ebpf(interface_name: impl Into<String>, ebpf: &'a mut aya::Ebpf) -> Result<Self> {
        let map = ebpf
            .map_mut(P0F_SIGNATURES_MAP)
            .ok_or_else(|| anyhow::anyhow!("{P0F_SIGNATURES_MAP} map is missing"))?;
        Ok(Self {
            interface_name: interface_name.into(),
            engine: P0fSignatureEngine::bundled()?,
            ring: aya::maps::RingBuf::try_from(map)?,
        })
    }

    pub fn poll_once(
        &mut self,
        tx: &tokio::sync::broadcast::Sender<FingerprintEvent>,
        gate: &std::sync::Arc<std::sync::Mutex<FingerprintEventGate>>,
        metrics: &Metrics,
    ) -> usize {
        let mut emitted = 0usize;
        while let Some(item) = self.ring.next() {
            let Some(event) = self
                .engine
                .event_from_ring_bytes(&self.interface_name, item.as_ref())
            else {
                continue;
            };
            let Some(event) = gate
                .lock()
                .expect("fingerprint event gate lock poisoned")
                .filter(event)
            else {
                continue;
            };
            metrics.inc_fingerprint_events();
            if tx.send(event).is_err() {
                metrics.inc_fingerprint_events_dropped("no_receiver", 1);
            } else {
                emitted += 1;
            }
        }

        emitted
    }
}

#[allow(dead_code)]
fn parse_p0f_ring_record(bytes: &[u8]) -> Option<P0fRingRecord> {
    if bytes.len() != P0F_RING_RECORD_LEN {
        return None;
    }

    let version = u16::from_ne_bytes(bytes.get(0..2)?.try_into().ok()?);
    let source_endpoint = *bytes.get(2)?;
    let flow_key = parse_flow_key(bytes.get(8..48)?)?;
    let observed_ns = u64::from_ne_bytes(bytes.get(48..56)?.try_into().ok()?);
    let p0f_len = usize::from(*bytes.get(152)?);
    if p0f_len > P0F_SIGNATURE_MAX_LEN {
        return None;
    }
    let p0f_bytes = bytes.get(56..56 + p0f_len)?;
    let p0f_signature = std::str::from_utf8(p0f_bytes).ok()?.to_string();

    Some(P0fRingRecord {
        version,
        source_endpoint,
        flow_key,
        observed_ns,
        p0f_signature,
    })
}

#[allow(dead_code)]
fn parse_flow_key(bytes: &[u8]) -> Option<FlowKey> {
    if bytes.len() != 40 {
        return None;
    }

    Some(FlowKey {
        address_family: u16::from_ne_bytes(bytes.get(0..2)?.try_into().ok()?),
        transport_protocol: u16::from_ne_bytes(bytes.get(2..4)?.try_into().ok()?),
        endpoint_a_port: u16::from_ne_bytes(bytes.get(4..6)?.try_into().ok()?),
        endpoint_b_port: u16::from_ne_bytes(bytes.get(6..8)?.try_into().ok()?),
        endpoint_a_addr: bytes.get(8..24)?.try_into().ok()?,
        endpoint_b_addr: bytes.get(24..40)?.try_into().ok()?,
    })
}

#[allow(dead_code)]
fn source_ip_from_flow_key(flow_key: &FlowKey, source_endpoint: u8) -> Option<IpAddr> {
    let bytes = match source_endpoint {
        FLOW_ENDPOINT_A => flow_key.endpoint_a_addr,
        FLOW_ENDPOINT_B => flow_key.endpoint_b_addr,
        _ => return None,
    };

    match flow_key.address_family {
        AF_INET => Some(IpAddr::V4(Ipv4Addr::new(
            bytes[0], bytes[1], bytes[2], bytes[3],
        ))),
        AF_INET6 => Some(IpAddr::V6(Ipv6Addr::from(bytes))),
        _ => None,
    }
}

#[cfg(feature = "pcap-capture")]
fn license_clean_events_from_payload(
    interface_name: &str,
    observed_at_unix_nano: i64,
    packet: &[u8],
) -> Vec<FingerprintEvent> {
    let Some((source_ip, payload)) = packet_source_and_payload(packet) else {
        return Vec::new();
    };
    let mut events = Vec::new();

    if let Some(ja4) = crate::ja4::fingerprint_tls_client_hello(payload) {
        events.push(license_clean_event(
            source_ip,
            interface_name,
            observed_at_unix_nano,
            LicenseCleanFingerprint {
                ja4,
                ..Default::default()
            },
        ));
    }

    if let Some(hassh_pair) = hassh::fingerprint_ssh_kexinit(payload) {
        events.push(license_clean_event(
            source_ip,
            interface_name,
            observed_at_unix_nano,
            LicenseCleanFingerprint {
                hassh: hassh_pair.client.md5,
                hassh_server: hassh_pair.server.md5,
                ..Default::default()
            },
        ));
    }

    events
}

#[allow(dead_code)]
fn license_clean_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    fingerprint: LicenseCleanFingerprint,
) -> FingerprintEvent {
    FingerprintEvent {
        ip: ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::LicenseClean(fingerprint)),
    }
}

#[allow(dead_code)]
fn proto_os_match(os_match: &os_matcher::OsMatch) -> ProtoOsMatch {
    ProtoOsMatch {
        name: os_match.name.clone(),
        version_range: os_match.version_range.clone().unwrap_or_default(),
        os_family: os_match.os_family.clone(),
        confidence: os_match.confidence,
        disagreements: os_match
            .disagreements
            .iter()
            .map(proto_disagreement)
            .collect(),
    }
}

#[allow(dead_code)]
fn proto_disagreement(disagreement: &SignalDisagreement) -> FingerprintDisagreement {
    FingerprintDisagreement {
        signal: signal_name(disagreement.signal).to_string(),
        signature: disagreement.signature.clone(),
        observed_family: disagreement.observed_family.clone(),
        observed_name: disagreement.observed_name.clone(),
        version_range: disagreement.version_range.clone().unwrap_or_default(),
    }
}

#[allow(dead_code)]
fn signal_name(signal: FingerprintSignal) -> &'static str {
    match signal {
        FingerprintSignal::Ja4 => "ja4",
        FingerprintSignal::Hassh => "hassh",
    }
}

#[cfg(feature = "pcap-capture")]
fn packet_source_and_payload(packet: &[u8]) -> Option<(IpAddr, &[u8])> {
    let headers = if matches!(packet.first().map(|byte| byte >> 4), Some(4 | 6)) {
        PacketHeaders::from_ip_slice(packet).ok()?
    } else {
        PacketHeaders::from_ethernet_slice(packet).ok()?
    };
    let source_ip = source_ip(headers.net.as_ref()?)?;
    match headers.transport.as_ref()? {
        TransportHeader::Tcp(_) => Some((source_ip, headers.payload.slice())),
        TransportHeader::Udp(_) => Some((source_ip, headers.payload.slice())),
        _ => None,
    }
}

#[cfg(feature = "pcap-capture")]
fn source_ip(headers: &NetHeaders) -> Option<IpAddr> {
    match headers {
        NetHeaders::Ipv4(header, _) => Some(IpAddr::from(header.source)),
        NetHeaders::Ipv6(header, _) => Some(IpAddr::from(header.source)),
        NetHeaders::Arp(_) => None,
    }
}

#[cfg(test)]
mod p0f_ring_tests {
    use super::{
        parse_p0f_ring_record, source_ip_from_flow_key, P0fSignatureEngine, AF_INET, EVENT_VERSION,
        FLOW_ENDPOINT_A, FLOW_ENDPOINT_B, P0F_RING_RECORD_LEN,
    };
    use crate::af_xdp_classifier::FlowKey;
    use crate::proto::netprobe::fingerprint_event;
    use std::net::{IpAddr, Ipv4Addr};

    #[test]
    fn parses_p0f_ring_record_and_preserves_source_endpoint() {
        let bytes = p0f_record_bytes(
            FLOW_ENDPOINT_B,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0",
        );

        let record = parse_p0f_ring_record(&bytes).unwrap();

        assert_eq!(record.version, EVENT_VERSION);
        assert_eq!(record.observed_ns, 123);
        assert_eq!(record.source_endpoint, FLOW_ENDPOINT_B);
        assert_eq!(
            source_ip_from_flow_key(&record.flow_key, record.source_endpoint),
            Some(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20)))
        );
        assert_eq!(
            record.p0f_signature,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0"
        );
    }

    #[test]
    fn builds_license_clean_event_from_p0f_ring_record() {
        let bytes = p0f_record_bytes(
            FLOW_ENDPOINT_B,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0",
        );
        let engine = P0fSignatureEngine::bundled().unwrap();

        let event = engine.event_from_ring_bytes("eth0", &bytes).unwrap();

        assert_eq!(event.ip, "198.51.100.20");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(event.observed_at_unix_nano, 123);
        let Some(fingerprint_event::Evidence::LicenseClean(fingerprint)) = event.evidence else {
            panic!("expected license-clean fingerprint");
        };
        assert_eq!(
            fingerprint.p0f_signature,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0"
        );
        assert_eq!(
            fingerprint
                .p0f_match
                .as_ref()
                .map(|matched| matched.name.as_str()),
            Some("Linux")
        );
        assert!(fingerprint.ja4.is_empty());
        assert!(fingerprint.hassh.is_empty());
    }

    #[test]
    fn rejects_malformed_p0f_ring_records() {
        assert!(parse_p0f_ring_record(&[0; P0F_RING_RECORD_LEN - 1]).is_none());

        let mut bytes = p0f_record_bytes(FLOW_ENDPOINT_A, "4:64:0:*:*,*:mss:df:0");
        bytes[152] = 255;

        assert!(parse_p0f_ring_record(&bytes).is_none());
    }

    fn p0f_record_bytes(source_endpoint: u8, signature: &str) -> Vec<u8> {
        let mut bytes = vec![0u8; P0F_RING_RECORD_LEN];
        bytes[0..2].copy_from_slice(&EVENT_VERSION.to_ne_bytes());
        bytes[2] = source_endpoint;
        write_flow_key(
            &mut bytes[8..48],
            FlowKey {
                address_family: AF_INET,
                transport_protocol: 6,
                endpoint_a_port: 443,
                endpoint_b_port: 51_234,
                endpoint_a_addr: ipv4_addr([192, 0, 2, 10]),
                endpoint_b_addr: ipv4_addr([198, 51, 100, 20]),
            },
        );
        bytes[48..56].copy_from_slice(&123u64.to_ne_bytes());
        bytes[56..56 + signature.len()].copy_from_slice(signature.as_bytes());
        bytes[152] = signature.len() as u8;
        bytes
    }

    fn write_flow_key(bytes: &mut [u8], flow_key: FlowKey) {
        bytes[0..2].copy_from_slice(&flow_key.address_family.to_ne_bytes());
        bytes[2..4].copy_from_slice(&flow_key.transport_protocol.to_ne_bytes());
        bytes[4..6].copy_from_slice(&flow_key.endpoint_a_port.to_ne_bytes());
        bytes[6..8].copy_from_slice(&flow_key.endpoint_b_port.to_ne_bytes());
        bytes[8..24].copy_from_slice(&flow_key.endpoint_a_addr);
        bytes[24..40].copy_from_slice(&flow_key.endpoint_b_addr);
    }

    fn ipv4_addr(addr: [u8; 4]) -> [u8; 16] {
        let mut out = [0u8; 16];
        out[..4].copy_from_slice(&addr);
        out
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

        let license_clean_ja4 = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::LicenseClean(fingerprint))
                if !fingerprint.ja4.is_empty() =>
            {
                Some((event, fingerprint))
            }
            _ => None,
        });
        let (event, fingerprint) =
            license_clean_ja4.expect("expected license-clean JA4 fingerprint event");
        assert_eq!(event.ip, "192.0.2.22");
        assert!(fingerprint.ja4.starts_with("t12i"));
        assert!(fingerprint.p0f_signature.is_empty());
        assert!(fingerprint.hassh.is_empty());

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
