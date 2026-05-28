use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::{Arc, Mutex},
};

#[cfg(target_os = "linux")]
use std::{
    sync::atomic::{AtomicBool, Ordering},
    thread::{self, JoinHandle},
    time::Duration,
};

#[cfg(feature = "remote-capture")]
use std::time::SystemTime;

#[cfg(any(feature = "remote-capture", target_os = "linux"))]
use anyhow::Result;
#[cfg(feature = "remote-capture")]
use etherparse::{NetHeaders, PacketHeaders, TcpHeader, TcpOptionElement, TransportHeader};

#[cfg(target_os = "linux")]
use crate::event_queue::EventSender;
use crate::hassh;
use crate::proto::netprobe::{
    fingerprint_event, FingerprintDisagreement, FingerprintEvent, FingerprintMatch,
    LicenseCleanFingerprint, OsMatch as ProtoOsMatch, P0fFingerprintMatch,
};
#[cfg(feature = "remote-capture")]
use crate::proto::netprobe::{HttpFingerprint, TcpFingerprint, TlsFingerprint};
use crate::{
    af_xdp_classifier::FlowKey,
    os_matcher::{self, FingerprintSignal, OsMatchInput, P0fObservation, SignalDisagreement},
    p0f_matcher::{P0fMatch, P0fMatcher},
};
#[cfg(target_os = "linux")]
use crate::{metrics::Metrics, runtime_config::FingerprintEventGate};

#[cfg(target_os = "linux")]
const P0F_RING_IDLE_SLEEP: Duration = Duration::from_millis(1);
const FINGERPRINT_ACCUMULATOR_TTL_NS: u64 = 30_000_000_000;

pub const FINGERPRINT_ENGINE_VERSION: &str = "serviceradar-license-clean/1";
pub const P0F_CORPUS_REVISION: &str =
    "p0f-3.09b:p0f.fp:sha256:45f27bcc65de0f64bc69356dc0662e3366e05e67a0e98fd2251808e253b6be40";
pub const SERVICERADAR_ADDITIONS_REVISION: &str =
    "serviceradar-additions.fp:sha256:2ab43ef6a172ec7329f77a5b8d01779c7c9b33e1f8e887981dbdb59e3debf68e";
pub const JA4_BASE_SPEC_REVISION: &str =
    "foxio-ja4-base:LICENSE-JA4:sha256:094300333d31ef3da914a2e8894dc933a39fc1c538bf1b58f9b37d08701ab29f";
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

#[derive(Clone, Debug, Default)]
pub struct FingerprintAccumulator {
    inner: Arc<Mutex<HashMap<FlowKey, AccumulatedFingerprint>>>,
}

#[derive(Clone, Debug, Default)]
struct AccumulatedFingerprint {
    ja4: Option<String>,
    hassh: Option<hassh::HasshPair>,
    last_observed_ns: u64,
}

impl FingerprintAccumulator {
    pub fn observe_dpi_payload(
        &self,
        flow_key: FlowKey,
        payload: &[u8],
        observed_at_unix_nano: i64,
    ) {
        let ja4 = crate::ja4::fingerprint_tls_client_hello(payload);
        let hassh = hassh::fingerprint_ssh_kexinit(payload);
        if ja4.is_none() && hassh.is_none() {
            return;
        }

        let observed_ns = observed_at_unix_nano.max(0) as u64;
        let mut inner = self
            .inner
            .lock()
            .expect("fingerprint accumulator lock poisoned");
        retain_recent(&mut inner, observed_ns);
        let entry = inner.entry(flow_key).or_default();
        entry.last_observed_ns = observed_ns;
        if let Some(ja4) = ja4 {
            entry.ja4 = Some(ja4);
        }
        if let Some(hassh) = hassh {
            entry.hassh = Some(hassh);
        }
    }

    fn snapshot(&self, flow_key: &FlowKey, observed_ns: u64) -> Option<AccumulatedFingerprint> {
        let mut inner = self
            .inner
            .lock()
            .expect("fingerprint accumulator lock poisoned");
        retain_recent(&mut inner, observed_ns);
        inner.get(flow_key).cloned()
    }
}

fn retain_recent(inner: &mut HashMap<FlowKey, AccumulatedFingerprint>, observed_ns: u64) {
    inner.retain(|_key, value| {
        observed_ns.saturating_sub(value.last_observed_ns) <= FINGERPRINT_ACCUMULATOR_TTL_NS
    });
}
#[cfg(target_os = "linux")]
#[allow(dead_code)]
const P0F_SIGNATURES_MAP: &str = "p0f_signatures";

#[cfg(feature = "remote-capture")]
pub struct FingerprintEngine {
    p0f_matcher: P0fMatcher,
}

#[cfg(feature = "remote-capture")]
impl FingerprintEngine {
    pub fn phase1() -> Result<Self> {
        Ok(Self {
            p0f_matcher: P0fMatcher::bundled()?,
        })
    }

    pub fn analyze_packet(
        &mut self,
        interface_name: &str,
        observed_at_unix_nano: i64,
        packet: &[u8],
    ) -> Vec<FingerprintEvent> {
        let mut events = Vec::new();

        if let Some(observation) = tcp_syn_observation(packet) {
            let matched = self.match_p0f(&observation.signature);
            events.push(tcp_event(
                observation.source_ip,
                interface_name,
                observed_at_unix_nano,
                &observation,
                matched.as_ref(),
            ));
            if let Some(matched) = matched {
                events.push(license_clean_p0f_event(
                    observation.source_ip,
                    interface_name,
                    observed_at_unix_nano,
                    observation.signature,
                    matched,
                ));
            }
        }

        events.extend(legacy_payload_events(
            interface_name,
            observed_at_unix_nano,
            packet,
        ));
        events.extend(license_clean_events_from_payload(
            interface_name,
            observed_at_unix_nano,
            packet,
        ));

        events
    }

    fn match_p0f(&self, p0f_signature: &str) -> Option<P0fMatch> {
        match self.p0f_matcher.match_signature(p0f_signature) {
            Ok(matched) => matched,
            Err(error) => {
                log::warn!("failed to match p0f signature {p0f_signature:?}: {error}");
                None
            }
        }
    }
}

#[cfg(feature = "remote-capture")]
pub fn now_unix_nano() -> i64 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as i64)
        .unwrap_or_default()
}

#[cfg(feature = "remote-capture")]
#[derive(Clone, Debug)]
struct TcpSynObservation {
    source_ip: IpAddr,
    signature: String,
    ttl: u8,
    window_size: u16,
    mss: u16,
    options_layout: Vec<String>,
    quirks: Vec<String>,
    ip_version: &'static str,
    window_scale: u8,
    payload_class: &'static str,
}

#[cfg(feature = "remote-capture")]
fn tcp_syn_observation(packet: &[u8]) -> Option<TcpSynObservation> {
    let headers = parse_headers(packet)?;
    let net = headers.net.as_ref()?;
    let TransportHeader::Tcp(tcp) = headers.transport.as_ref()? else {
        return None;
    };
    if !tcp.syn {
        return None;
    }

    let source_ip = source_ip(net)?;
    let ip_meta = ip_metadata(net)?;
    let payload_class = if headers.payload.slice().is_empty() {
        "0"
    } else {
        "+"
    };
    let (options_layout, mss, window_scale, option_quirks) = tcp_options(tcp);
    let mut quirks = ip_meta.quirks;
    quirks.extend(option_quirks);

    let options = options_layout.join(",");
    let quirks_field = quirks.join(",");
    let signature = format!(
        "{}:{}:{}:{}:{},{}:{}:{}:{}",
        ip_meta.version,
        ip_meta.ttl,
        ip_meta.options_len,
        mss.map(|value| value.to_string())
            .unwrap_or_else(|| "*".to_string()),
        tcp.window_size,
        window_scale
            .map(|value| value.to_string())
            .unwrap_or_else(|| "*".to_string()),
        options,
        quirks_field,
        payload_class,
    );

    Some(TcpSynObservation {
        source_ip,
        signature,
        ttl: ip_meta.ttl,
        window_size: tcp.window_size,
        mss: mss.unwrap_or_default(),
        options_layout,
        quirks,
        ip_version: ip_meta.version,
        window_scale: window_scale.unwrap_or_default(),
        payload_class,
    })
}

#[cfg(feature = "remote-capture")]
struct IpMetadata {
    version: &'static str,
    ttl: u8,
    options_len: usize,
    quirks: Vec<String>,
}

#[cfg(feature = "remote-capture")]
fn ip_metadata(headers: &NetHeaders) -> Option<IpMetadata> {
    match headers {
        NetHeaders::Ipv4(header, _) => {
            let mut quirks = Vec::new();
            if header.dont_fragment {
                quirks.push("df".to_string());
                if header.identification != 0 {
                    quirks.push("id+".to_string());
                }
            } else if header.identification == 0 {
                quirks.push("id-".to_string());
            }
            if header.ecn.value() != 0 {
                quirks.push("ecn".to_string());
            }

            Some(IpMetadata {
                version: "4",
                ttl: header.time_to_live,
                options_len: header.options.as_slice().len(),
                quirks,
            })
        }
        NetHeaders::Ipv6(header, _) => Some(IpMetadata {
            version: "6",
            ttl: header.hop_limit,
            options_len: 0,
            quirks: Vec::new(),
        }),
        NetHeaders::Arp(_) => None,
    }
}

#[cfg(feature = "remote-capture")]
fn tcp_options(tcp: &TcpHeader) -> (Vec<String>, Option<u16>, Option<u8>, Vec<String>) {
    let mut layout = Vec::new();
    let mut mss = None;
    let mut window_scale = None;
    let mut quirks = Vec::new();

    for option in tcp.options_iterator() {
        match option {
            Ok(TcpOptionElement::Noop) => layout.push("nop".to_string()),
            Ok(TcpOptionElement::MaximumSegmentSize(value)) => {
                mss = Some(value);
                layout.push("mss".to_string());
            }
            Ok(TcpOptionElement::WindowScale(value)) => {
                window_scale = Some(value);
                layout.push("ws".to_string());
                if value > 14 {
                    quirks.push("exws".to_string());
                }
            }
            Ok(TcpOptionElement::SelectiveAcknowledgementPermitted) => {
                layout.push("sok".to_string());
            }
            Ok(TcpOptionElement::SelectiveAcknowledgement(_, _)) => {
                layout.push("sack".to_string());
            }
            Ok(TcpOptionElement::Timestamp(own, peer)) => {
                layout.push("ts".to_string());
                if own == 0 {
                    quirks.push("ts1-".to_string());
                }
                if peer != 0 {
                    quirks.push("ts2+".to_string());
                }
            }
            Err(_) => {
                quirks.push("bad".to_string());
            }
        }
    }

    (layout, mss, window_scale, quirks)
}

#[cfg(feature = "remote-capture")]
fn tcp_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    observation: &TcpSynObservation,
    matched: Option<&P0fMatch>,
) -> FingerprintEvent {
    let (os_family, os_name, confidence) = matched
        .map(|matched| {
            (
                matched.label.class.clone().unwrap_or_default(),
                matched
                    .label
                    .flavor
                    .as_ref()
                    .map(|flavor| format!("{} {flavor}", matched.label.name))
                    .unwrap_or_else(|| matched.label.name.clone()),
                0.65,
            )
        })
        .unwrap_or_else(|| (String::new(), String::new(), 0.0));

    FingerprintEvent {
        ip: ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Tcp(TcpFingerprint {
            signature: observation.signature.clone(),
            os_family,
            os_name,
            confidence,
            ttl: u32::from(observation.ttl),
            window_size: observation.window_size.to_string(),
            mss: u32::from(observation.mss),
            options_layout: observation.options_layout.clone(),
            quirks: observation.quirks.clone(),
            ip_version: observation.ip_version.to_string(),
            window_scale: u32::from(observation.window_scale),
            payload_class: observation.payload_class.to_string(),
        })),
    }
}

#[cfg(feature = "remote-capture")]
fn legacy_payload_events(
    interface_name: &str,
    observed_at_unix_nano: i64,
    packet: &[u8],
) -> Vec<FingerprintEvent> {
    let Some((source_ip, payload)) = packet_source_and_payload(packet) else {
        return Vec::new();
    };
    let mut events = Vec::new();

    if let Some(fingerprint) = http_request_fingerprint(payload) {
        events.push(http_event(
            source_ip,
            interface_name,
            observed_at_unix_nano,
            fingerprint,
        ));
    }
    if let Some(fingerprint) = http_response_fingerprint(payload) {
        events.push(http_event(
            source_ip,
            interface_name,
            observed_at_unix_nano,
            fingerprint,
        ));
    }
    if let Some(client_hello) = crate::ja4::parse_tls_client_hello(payload) {
        events.push(tls_event(
            source_ip,
            interface_name,
            observed_at_unix_nano,
            TlsFingerprint {
                ja4: crate::ja4::fingerprint(&client_hello),
                ja4s: String::new(),
                sni_redacted: redact_sni_presence(client_hello.has_sni).to_string(),
            },
        ));
    }
    if let Some(tls_server) = crate::tls_server::fingerprint(packet) {
        events.push(tls_event(
            tls_server.source_ip,
            interface_name,
            observed_at_unix_nano,
            TlsFingerprint {
                ja4: String::new(),
                ja4s: tls_server.ja4s,
                sni_redacted: String::new(),
            },
        ));
    }

    events
}

#[cfg(feature = "remote-capture")]
fn http_request_fingerprint(payload: &[u8]) -> Option<HttpFingerprint> {
    let headers = http_headers(payload)?;
    if !is_http_request_start(headers.first_line) {
        return None;
    }

    let user_agent = header_value(headers.headers, "user-agent").unwrap_or_default();
    let accept_language = header_value(headers.headers, "accept-language").unwrap_or_default();
    if user_agent.is_empty() && accept_language.is_empty() {
        return None;
    }

    Some(HttpFingerprint {
        user_agent,
        server: String::new(),
        accept_language,
    })
}

#[cfg(feature = "remote-capture")]
fn http_response_fingerprint(payload: &[u8]) -> Option<HttpFingerprint> {
    let headers = http_headers(payload)?;
    if !headers.first_line.starts_with("HTTP/") {
        return None;
    }

    let server = header_value(headers.headers, "server").unwrap_or_default();
    if server.is_empty() {
        return None;
    }

    Some(HttpFingerprint {
        user_agent: String::new(),
        server,
        accept_language: String::new(),
    })
}

#[cfg(feature = "remote-capture")]
struct HttpHeaders<'a> {
    first_line: &'a str,
    headers: &'a str,
}

#[cfg(feature = "remote-capture")]
fn http_headers(payload: &[u8]) -> Option<HttpHeaders<'_>> {
    let text = std::str::from_utf8(payload).ok()?;
    let end = text.find("\r\n\r\n").or_else(|| text.find("\n\n"))?;
    let head = &text[..end];
    let (first_line, headers) = head.split_once('\n').unwrap_or((head, ""));
    Some(HttpHeaders {
        first_line: first_line.trim_end_matches('\r'),
        headers,
    })
}

#[cfg(feature = "remote-capture")]
fn is_http_request_start(line: &str) -> bool {
    matches!(
        line.split_ascii_whitespace().next(),
        Some("GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS" | "TRACE")
    )
}

#[cfg(feature = "remote-capture")]
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

#[cfg(feature = "remote-capture")]
fn header_value(headers: &str, name: &str) -> Option<String> {
    headers
        .lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once(':'))
        .find(|(header_name, _value)| header_name.eq_ignore_ascii_case(name))
        .map(|(_header_name, value)| value.trim().to_string())
}

#[cfg(feature = "remote-capture")]
fn tls_event(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    fingerprint: TlsFingerprint,
) -> FingerprintEvent {
    FingerprintEvent {
        ip: ip.to_string(),
        profile_id: String::new(),
        interface_name: interface_name.to_string(),
        observed_at_unix_nano,
        evidence: Some(fingerprint_event::Evidence::Tls(fingerprint)),
    }
}

#[cfg(feature = "remote-capture")]
fn redact_sni_presence(has_sni: bool) -> &'static str {
    if has_sni {
        "<present>"
    } else {
        ""
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
    license_clean_p0f_event_with_accumulated(
        ip,
        interface_name,
        observed_at_unix_nano,
        p0f_signature,
        matched,
        None,
    )
}

#[allow(dead_code)]
fn license_clean_p0f_event_with_accumulated(
    ip: IpAddr,
    interface_name: &str,
    observed_at_unix_nano: i64,
    p0f_signature: String,
    matched: P0fMatch,
    accumulated: Option<AccumulatedFingerprint>,
) -> FingerprintEvent {
    let ja4_observation = accumulated
        .as_ref()
        .and_then(|fingerprint| fingerprint.ja4.as_ref())
        .map(|signature| {
            auxiliary_observation(FingerprintSignal::Ja4, signature.clone(), &matched)
        });
    let hassh_observation = accumulated
        .as_ref()
        .and_then(|fingerprint| fingerprint.hassh.as_ref())
        .map(|pair| {
            auxiliary_observation(FingerprintSignal::Hassh, pair.client.md5.clone(), &matched)
        });
    let os_match = os_matcher::evaluate(OsMatchInput {
        p0f: Some(P0fObservation {
            signature: p0f_signature,
            matched,
        }),
        muonfp: None,
        ja4: ja4_observation.clone(),
        hassh: hassh_observation.clone(),
    })
    .expect("p0f observation is present");
    let ja4 = accumulated
        .as_ref()
        .and_then(|fingerprint| fingerprint.ja4.clone())
        .unwrap_or_default();
    let hassh = accumulated
        .as_ref()
        .and_then(|fingerprint| {
            fingerprint
                .hassh
                .as_ref()
                .map(|pair| pair.client.md5.clone())
        })
        .unwrap_or_default();
    let hassh_server = accumulated
        .as_ref()
        .and_then(|fingerprint| {
            fingerprint
                .hassh
                .as_ref()
                .map(|pair| pair.server.md5.clone())
        })
        .unwrap_or_default();

    license_clean_event(
        ip,
        interface_name,
        observed_at_unix_nano,
        LicenseCleanFingerprint {
            p0f_signature: os_match.p0f_signature.clone().unwrap_or_default(),
            p0f_match: os_match
                .p0f_label
                .as_ref()
                .map(|label| P0fFingerprintMatch {
                    label: label.raw.clone(),
                    name: label.name.clone(),
                    version_flavor: label.flavor.clone().unwrap_or_default(),
                    os_family: os_matcher::family_from_p0f_label(label),
                }),
            ja4,
            ja4_match: ja4_observation.as_ref().map(proto_fingerprint_match),
            hassh,
            hassh_server,
            hassh_match: hassh_observation.as_ref().map(proto_fingerprint_match),
            os_match: Some(proto_os_match(&os_match)),
            agreement_count: os_match.agreement_count,
        },
    )
}

fn auxiliary_observation(
    signal: FingerprintSignal,
    signature: String,
    matched: &P0fMatch,
) -> os_matcher::FingerprintObservation {
    os_matcher::FingerprintObservation {
        signal,
        signature,
        os_family: os_matcher::family_from_p0f_label(&matched.label),
        name: matched.label.name.clone(),
        version_range: matched.label.flavor.clone(),
    }
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
        self.event_from_ring_record_with_accumulator(interface_name, record, None)
    }

    fn event_from_ring_record_with_accumulator(
        &self,
        interface_name: &str,
        record: &P0fRingRecord,
        accumulator: Option<&FingerprintAccumulator>,
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
        let accumulated = accumulator
            .and_then(|accumulator| accumulator.snapshot(&record.flow_key, record.observed_ns));

        Some(license_clean_p0f_event_with_accumulated(
            source_ip,
            interface_name,
            record.observed_ns.min(i64::MAX as u64) as i64,
            record.p0f_signature.clone(),
            matched,
            accumulated,
        ))
    }

    pub fn event_from_ring_bytes(
        &self,
        interface_name: &str,
        bytes: &[u8],
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record(interface_name, &parse_p0f_ring_record(bytes)?)
    }

    fn event_from_ring_bytes_with_accumulator(
        &self,
        interface_name: &str,
        bytes: &[u8],
        accumulator: Option<&FingerprintAccumulator>,
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record_with_accumulator(
            interface_name,
            &parse_p0f_ring_record(bytes)?,
            accumulator,
        )
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
        tx: &EventSender<FingerprintEvent>,
        gate: &std::sync::Arc<std::sync::Mutex<FingerprintEventGate>>,
        metrics: &Metrics,
        accumulator: Option<&FingerprintAccumulator>,
    ) -> usize {
        let mut emitted = 0usize;
        while let Some(item) = self.ring.next() {
            let Some(event) = self.engine.event_from_ring_bytes_with_accumulator(
                &self.interface_name,
                item.as_ref(),
                accumulator,
            ) else {
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
            if tx.try_send(event).is_err() {
                metrics.inc_fingerprint_events_dropped("ipc_queue_full", 1);
            } else {
                emitted += 1;
            }
        }

        emitted
    }
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
pub struct P0fSignatureRuntime {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
impl P0fSignatureRuntime {
    pub fn start_from_ebpf(
        interface_name: impl Into<String>,
        ebpf: &mut aya::Ebpf,
        tx: EventSender<FingerprintEvent>,
        gate: Arc<Mutex<FingerprintEventGate>>,
        accumulator: FingerprintAccumulator,
        metrics: Metrics,
    ) -> Result<Self> {
        let map = ebpf
            .take_map(P0F_SIGNATURES_MAP)
            .ok_or_else(|| anyhow::anyhow!("{P0F_SIGNATURES_MAP} map is missing"))?;
        let mut consumer = P0fSignatureConsumer {
            interface_name: interface_name.into(),
            engine: P0fSignatureEngine::bundled()?,
            ring: aya::maps::RingBuf::try_from(map)?,
        };
        let stop = Arc::new(AtomicBool::new(false));
        let stop_worker = Arc::clone(&stop);
        let thread = thread::Builder::new()
            .name("netprobe-p0f-signature-ring".to_owned())
            .spawn(move || {
                while !stop_worker.load(Ordering::Relaxed) {
                    if consumer.poll_once(&tx, &gate, &metrics, Some(&accumulator)) == 0 {
                        thread::sleep(P0F_RING_IDLE_SLEEP);
                    }
                }
            })?;

        Ok(Self {
            stop,
            thread: Some(thread),
        })
    }
}

#[cfg(target_os = "linux")]
impl Drop for P0fSignatureRuntime {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            if thread.join().is_err() {
                log::warn!("p0f signature ring thread panicked during shutdown");
            }
        }
    }
}

#[cfg(target_os = "linux")]
struct P0fSignatureConsumer {
    interface_name: String,
    engine: P0fSignatureEngine,
    ring: aya::maps::RingBuf<aya::maps::MapData>,
}

#[cfg(target_os = "linux")]
impl P0fSignatureConsumer {
    fn poll_once(
        &mut self,
        tx: &EventSender<FingerprintEvent>,
        gate: &Arc<Mutex<FingerprintEventGate>>,
        metrics: &Metrics,
        accumulator: Option<&FingerprintAccumulator>,
    ) -> usize {
        let mut emitted = 0usize;
        while let Some(item) = self.ring.next() {
            let Some(event) = self.engine.event_from_ring_bytes_with_accumulator(
                &self.interface_name,
                item.as_ref(),
                accumulator,
            ) else {
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
            if tx.try_send(event).is_err() {
                metrics.inc_fingerprint_events_dropped("ipc_queue_full", 1);
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

#[cfg(feature = "remote-capture")]
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
fn proto_fingerprint_match(observation: &os_matcher::FingerprintObservation) -> FingerprintMatch {
    FingerprintMatch {
        name: observation.name.clone(),
        version_range: observation.version_range.clone().unwrap_or_default(),
        os_family: observation.os_family.clone(),
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
        FingerprintSignal::MuonFp => "muonfp",
        FingerprintSignal::Ja4 => "ja4",
        FingerprintSignal::Hassh => "hassh",
    }
}

#[cfg(feature = "remote-capture")]
fn packet_source_and_payload(packet: &[u8]) -> Option<(IpAddr, &[u8])> {
    let headers = parse_headers(packet)?;
    let source_ip = source_ip(headers.net.as_ref()?)?;
    match headers.transport.as_ref()? {
        TransportHeader::Tcp(_) => Some((source_ip, headers.payload.slice())),
        TransportHeader::Udp(_) => Some((source_ip, headers.payload.slice())),
        _ => None,
    }
}

#[cfg(feature = "remote-capture")]
fn parse_headers(packet: &[u8]) -> Option<PacketHeaders<'_>> {
    if matches!(packet.first().map(|byte| byte >> 4), Some(4 | 6)) {
        PacketHeaders::from_ip_slice(packet).ok()
    } else {
        PacketHeaders::from_ethernet_slice(packet).ok()
    }
}

#[cfg(feature = "remote-capture")]
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
        parse_p0f_ring_record, source_ip_from_flow_key, FingerprintAccumulator, P0fSignatureEngine,
        AF_INET, EVENT_VERSION, FLOW_ENDPOINT_A, FLOW_ENDPOINT_B, P0F_RING_RECORD_LEN,
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
    fn enriches_p0f_ring_event_with_accumulated_ja4() {
        let bytes = p0f_record_bytes(
            FLOW_ENDPOINT_B,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0",
        );
        let record = parse_p0f_ring_record(&bytes).unwrap();
        let accumulator = FingerprintAccumulator::default();
        accumulator.observe_dpi_payload(record.flow_key, &tls_client_hello_payload(), 124);
        let engine = P0fSignatureEngine::bundled().unwrap();

        let event = engine
            .event_from_ring_record_with_accumulator("eth0", &record, Some(&accumulator))
            .unwrap();

        let Some(fingerprint_event::Evidence::LicenseClean(fingerprint)) = event.evidence else {
            panic!("expected license-clean fingerprint");
        };
        assert!(!fingerprint.ja4.is_empty());
        assert_eq!(
            fingerprint
                .ja4_match
                .as_ref()
                .map(|matched| matched.os_family.as_str()),
            Some("linux")
        );
        assert_eq!(fingerprint.agreement_count, 2);
        assert!(
            fingerprint
                .os_match
                .as_ref()
                .expect("expected OS match")
                .confidence
                > 0.72
        );
    }

    #[test]
    fn enriches_p0f_ring_event_with_accumulated_hassh() {
        let bytes = p0f_record_bytes(
            FLOW_ENDPOINT_B,
            "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0",
        );
        let record = parse_p0f_ring_record(&bytes).unwrap();
        let accumulator = FingerprintAccumulator::default();
        accumulator.observe_dpi_payload(record.flow_key, &ssh_kexinit_payload(), 124);
        let engine = P0fSignatureEngine::bundled().unwrap();

        let event = engine
            .event_from_ring_record_with_accumulator("eth0", &record, Some(&accumulator))
            .unwrap();

        let Some(fingerprint_event::Evidence::LicenseClean(fingerprint)) = event.evidence else {
            panic!("expected license-clean fingerprint");
        };
        assert!(!fingerprint.hassh.is_empty());
        assert!(!fingerprint.hassh_server.is_empty());
        assert_eq!(
            fingerprint
                .hassh_match
                .as_ref()
                .map(|matched| matched.os_family.as_str()),
            Some("linux")
        );
        assert_eq!(fingerprint.agreement_count, 2);
        assert!(
            fingerprint
                .os_match
                .as_ref()
                .expect("expected OS match")
                .confidence
                > 0.72
        );
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

    fn ssh_kexinit_payload() -> Vec<u8> {
        let mut payload = vec![20];
        payload.extend_from_slice(&[7u8; 16]);
        push_name_list(&mut payload, "curve25519-sha256");
        push_name_list(&mut payload, "ssh-ed25519");
        push_name_list(&mut payload, "chacha20-poly1305@openssh.com");
        push_name_list(&mut payload, "aes128-ctr");
        push_name_list(&mut payload, "hmac-sha2-256");
        push_name_list(&mut payload, "hmac-sha1");
        push_name_list(&mut payload, "none");
        push_name_list(&mut payload, "zlib@openssh.com");
        push_name_list(&mut payload, "");
        push_name_list(&mut payload, "");
        payload.push(0);
        payload.extend_from_slice(&0u32.to_be_bytes());

        let block_size = 8usize;
        let mut padding_len = block_size - ((payload.len() + 5) % block_size);
        if padding_len < 4 {
            padding_len += block_size;
        }
        let packet_len = payload.len() + padding_len + 1;

        let mut packet = Vec::new();
        packet.extend_from_slice(&(packet_len as u32).to_be_bytes());
        packet.push(padding_len as u8);
        packet.extend_from_slice(&payload);
        packet.extend(std::iter::repeat_n(0, padding_len));
        packet
    }

    fn push_name_list(out: &mut Vec<u8>, value: &str) {
        out.extend_from_slice(&(value.len() as u32).to_be_bytes());
        out.extend_from_slice(value.as_bytes());
    }
}

#[cfg(all(test, feature = "remote-capture"))]
mod tests {
    use super::{header_value, redact_sni_presence, FingerprintEngine};
    use crate::proto::netprobe::fingerprint_event;
    use std::io::Write;

    #[test]
    fn emits_tcp_fingerprint_for_ipv4_syn_packet() {
        let mut engine = FingerprintEngine::phase1().unwrap();

        let events = engine.analyze_packet("eth0", 123, ipv4_syn_packet());

        assert_eq!(events.len(), 2);
        let tcp_event = events
            .iter()
            .find(|event| matches!(event.evidence, Some(fingerprint_event::Evidence::Tcp(_))))
            .expect("expected TCP fingerprint event");
        assert_eq!(tcp_event.ip, "192.0.2.10");
        assert_eq!(tcp_event.interface_name, "eth0");
        assert_eq!(tcp_event.observed_at_unix_nano, 123);
        let Some(fingerprint_event::Evidence::Tcp(tcp)) = &tcp_event.evidence else {
            panic!("expected TCP fingerprint event");
        };
        assert!(!tcp.signature.is_empty());
        assert_license_clean_linux_p0f(&events, "192.0.2.10", 123);
    }

    #[test]
    fn ignores_non_tcp_packets() {
        let mut engine = FingerprintEngine::phase1().unwrap();

        let events = engine.analyze_packet("eth0", 123, &[0, 1, 2, 3]);

        assert!(events.is_empty());
    }

    #[test]
    fn finds_http_header_values_case_insensitively() {
        let headers = "Host: example.com\r\nUser-Agent: ServiceRadar Test\r\n";

        assert_eq!(
            header_value(headers, "user-agent"),
            Some("ServiceRadar Test".to_string())
        );
    }

    #[test]
    fn redacts_sni_values_to_presence_only() {
        assert_eq!(redact_sni_presence(true), "<present>");
        assert_eq!(redact_sni_presence(false), "");
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

    fn assert_license_clean_linux_p0f(
        events: &[crate::proto::netprobe::FingerprintEvent],
        expected_ip: &str,
        expected_observed_at: i64,
    ) {
        let license_clean_p0f = events.iter().find_map(|event| match &event.evidence {
            Some(fingerprint_event::Evidence::LicenseClean(fingerprint))
                if !fingerprint.p0f_signature.is_empty() =>
            {
                Some((event, fingerprint))
            }
            _ => None,
        });
        let (event, fingerprint) =
            license_clean_p0f.expect("expected license-clean p0f fingerprint event");
        assert_eq!(event.ip, expected_ip);
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(event.observed_at_unix_nano, expected_observed_at);
        assert!(fingerprint.p0f_signature.starts_with("4:64:0:1460:"));
        assert_eq!(
            fingerprint
                .p0f_match
                .as_ref()
                .expect("expected p0f match")
                .name,
            "Linux"
        );
        assert_eq!(
            fingerprint
                .os_match
                .as_ref()
                .expect("expected OS match")
                .name,
            "Linux"
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
