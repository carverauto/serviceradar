use std::{
    collections::HashMap,
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::{Arc, Mutex},
};
// Only the Linux ring-reader publishes fingerprints.
#[cfg(target_os = "linux")]
use tokio::sync::broadcast;

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

use crate::hassh;
use crate::proto::netprobe::{
    FingerprintDisagreement, FingerprintEvent, FingerprintMatch, LicenseCleanFingerprint,
    OsMatch as ProtoOsMatch, P0fFingerprintMatch, RecogFingerprintMatch, fingerprint_event,
};
#[cfg(feature = "remote-capture")]
use crate::proto::netprobe::{HttpFingerprint, TcpFingerprint, TlsFingerprint};
use crate::recog::{self, RecogLabel, RecogService};
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
pub const SERVICERADAR_ADDITIONS_REVISION: &str = "serviceradar-additions.fp:sha256:2ab43ef6a172ec7329f77a5b8d01779c7c9b33e1f8e887981dbdb59e3debf68e";
pub const JA4_BASE_SPEC_REVISION: &str = "foxio-ja4-base:LICENSE-JA4:sha256:094300333d31ef3da914a2e8894dc933a39fc1c538bf1b58f9b37d08701ab29f";
pub const MUONFP_CORPUS_REVISION: &str = "muonfp:fa507cc944ebbf63d6748cbdeda9f4c4b0680791:spec-sha256:955be749c4010bdc8bf52a3b4e3e95d062225c6d20fa222de2fe5b509f47363c";
pub const RECOG_CORPUS_REVISION: &str = "recog:v3.1.25:2d99f217e70aeca8f1c9a1fb298f88a2211292a3:xml-sha256:0e334bf22024b0490e75c9e0f4c7019ce2adee1789cd00cb986387c3d842ef29";
pub const SATORI_CORPUS_REVISION: &str = "satori:73fa88fe6549995c68760be10631382df4ec1d1c:xml-sha256:71f053ec3623b7aed65a18ee81980ff42872032b97141a808cf74044fc45b30b";
pub const SERVICERADAR_RECOG_ADDITIONS_REVISION: &str = "serviceradar-recog-additions:none";
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
// Wire size of the eBPF TcpSynSignatureRecord (#[repr(C)], see
// rust/netprobe/ebpf/src/lib.rs). Userspace decodes it then builds the p0f
// signature string itself via crate::p0f_encode.
#[allow(dead_code)]
const TCP_SYN_RING_RECORD_LEN: usize = 104;

#[derive(Clone, Debug, Default)]
pub struct FingerprintAccumulator {
    inner: Arc<Mutex<HashMap<FlowKey, AccumulatedFingerprint>>>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct DpiPayloadContext {
    pub flow_key: FlowKey,
    pub source_port: u16,
    pub destination_port: u16,
    pub transport_protocol: &'static str,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RecogObservation {
    pub service: RecogService,
    pub label: RecogLabel,
}

#[derive(Clone, Debug, Default)]
struct AccumulatedFingerprint {
    ja4: Option<String>,
    hassh: Option<hassh::HasshPair>,
    recog_matches: Vec<RecogObservation>,
    last_observed_ns: u64,
}

impl FingerprintAccumulator {
    pub fn observe_dpi_payload(
        &self,
        flow_key: FlowKey,
        payload: &[u8],
        observed_at_unix_nano: i64,
    ) {
        self.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key,
                source_port: 0,
                destination_port: 0,
                transport_protocol: "",
            },
            payload,
            observed_at_unix_nano,
        );
    }

    pub fn observe_dpi_payload_with_context(
        &self,
        context: DpiPayloadContext,
        payload: &[u8],
        observed_at_unix_nano: i64,
    ) {
        let ja4 = crate::ja4::fingerprint_tls_client_hello(payload);
        let hassh = hassh::fingerprint_ssh_kexinit(payload);
        let recog_matches = recog_observations(payload, context);
        if ja4.is_none() && hassh.is_none() && recog_matches.is_empty() {
            return;
        }

        let observed_ns = observed_at_unix_nano.max(0) as u64;
        let mut inner = self
            .inner
            .lock()
            .expect("fingerprint accumulator lock poisoned");
        retain_recent(&mut inner, observed_ns);
        let entry = inner.entry(context.flow_key).or_default();
        entry.last_observed_ns = observed_ns;
        if let Some(ja4) = ja4 {
            entry.ja4 = Some(ja4);
        }
        if let Some(hassh) = hassh {
            entry.hassh = Some(hassh);
        }
        upsert_recog_matches(entry, recog_matches);
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

fn upsert_recog_matches(entry: &mut AccumulatedFingerprint, recog_matches: Vec<RecogObservation>) {
    for matched in recog_matches {
        if let Some(existing) = entry
            .recog_matches
            .iter_mut()
            .find(|existing| existing.service == matched.service)
        {
            *existing = matched;
        } else {
            entry.recog_matches.push(matched);
        }
    }
}

fn recog_observations(payload: &[u8], context: DpiPayloadContext) -> Vec<RecogObservation> {
    let mut observations = Vec::new();

    if let Some(server) = http_response_server_banner(payload) {
        push_recog_match(&mut observations, RecogService::HttpServer, server);
    }
    if let Some(ssh) = ssh_banner(payload) {
        push_recog_match(&mut observations, RecogService::SshBanner, ssh);
    }
    if context.transport_protocol == "tcp"
        && has_port(context, 21)
        && let Some(ftp) = status_line_banner(payload)
    {
        push_recog_match(&mut observations, RecogService::FtpBanner, ftp);
    }
    if context.transport_protocol == "tcp"
        && [25, 465, 587].iter().any(|port| has_port(context, *port))
        && let Some(smtp) = status_line_banner(payload)
    {
        push_recog_match(&mut observations, RecogService::SmtpBanner, smtp);
    }
    if context.transport_protocol == "tcp"
        && has_port(context, 23)
        && let Some(telnet) = first_text_line(payload)
    {
        push_recog_match(&mut observations, RecogService::TelnetBanner, telnet);
    }
    if context.transport_protocol == "tcp"
        && [139, 445].iter().any(|port| has_port(context, *port))
        && let Some(smb) = first_text_line(payload)
    {
        push_recog_match(&mut observations, RecogService::SmbVersion, smb);
    }
    if context.transport_protocol == "udp"
        && has_port(context, 161)
        && let Some(snmp) = first_text_line(payload)
    {
        push_recog_match(&mut observations, RecogService::SnmpBanner, snmp);
    }
    if has_port(context, 5060)
        && let Some(sip) = sip_banner(payload)
    {
        push_recog_match(&mut observations, RecogService::SipBanner, sip);
    }
    if context.transport_protocol == "tcp"
        && has_port(context, 3389)
        && let Some(rdp) = first_text_line(payload)
    {
        push_recog_match(&mut observations, RecogService::RdpBanner, rdp);
    }
    if has_port(context, 53)
        && let Some(dns_version) = dns_version_bind_banner(payload)
    {
        push_recog_match(&mut observations, RecogService::DnsVersion, dns_version);
    }

    observations
}

fn push_recog_match(observations: &mut Vec<RecogObservation>, service: RecogService, banner: &str) {
    if let Some(label) = recog::match_recog(service, banner) {
        observations.push(RecogObservation { service, label });
    }
}

fn has_port(context: DpiPayloadContext, port: u16) -> bool {
    context.source_port == port || context.destination_port == port
}

fn http_response_server_banner(payload: &[u8]) -> Option<&str> {
    let headers = http_text_headers(payload)?;
    if !headers.first_line.starts_with("HTTP/") {
        return None;
    }
    header_value_ref(headers.headers, "server")
}

fn sip_banner(payload: &[u8]) -> Option<&str> {
    let headers = http_text_headers(payload)?;
    if !headers.first_line.starts_with("SIP/2.0") && !headers.first_line.ends_with(" SIP/2.0") {
        return None;
    }

    header_value_ref(headers.headers, "server")
        .or_else(|| header_value_ref(headers.headers, "user-agent"))
}

struct TextHeaders<'a> {
    first_line: &'a str,
    headers: &'a str,
}

fn http_text_headers(payload: &[u8]) -> Option<TextHeaders<'_>> {
    let text = std::str::from_utf8(payload).ok()?;
    let end = text.find("\r\n\r\n").or_else(|| text.find("\n\n"))?;
    let head = &text[..end];
    let (first_line, headers) = head.split_once('\n').unwrap_or((head, ""));
    Some(TextHeaders {
        first_line: first_line.trim_end_matches('\r'),
        headers,
    })
}

fn header_value_ref<'a>(headers: &'a str, name: &str) -> Option<&'a str> {
    headers
        .lines()
        .filter_map(|line| line.trim_end_matches('\r').split_once(':'))
        .find(|(header_name, _value)| header_name.eq_ignore_ascii_case(name))
        .map(|(_header_name, value)| value.trim())
        .filter(|value| !value.is_empty())
}

fn ssh_banner(payload: &[u8]) -> Option<&str> {
    let line = first_text_line(payload)?;
    line.strip_prefix("SSH-2.0-")
        .or_else(|| line.strip_prefix("SSH-1.99-"))
        .or_else(|| line.strip_prefix("SSH-1.5-"))
        .or(Some(line))
}

fn status_line_banner(payload: &[u8]) -> Option<&str> {
    let line = first_text_line(payload)?;
    let Some(rest) = line.get(3..) else {
        return Some(line);
    };
    if line
        .as_bytes()
        .get(..3)
        .is_some_and(|code| code.iter().all(u8::is_ascii_digit))
    {
        Some(rest.trim_start())
    } else {
        Some(line)
    }
}

fn first_text_line(payload: &[u8]) -> Option<&str> {
    let text = std::str::from_utf8(payload).ok()?;
    text.lines()
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
}

fn dns_version_bind_banner(payload: &[u8]) -> Option<&str> {
    let message = dns_message_slice(payload)?;
    if message.len() < 12 {
        return None;
    }
    let qdcount = u16::from_be_bytes([message[4], message[5]]) as usize;
    let ancount = u16::from_be_bytes([message[6], message[7]]) as usize;
    if ancount == 0 {
        return None;
    }

    let mut offset = 12;
    for _ in 0..qdcount {
        skip_dns_name(message, &mut offset)?;
        offset = offset.checked_add(4)?;
        if offset > message.len() {
            return None;
        }
    }

    for _ in 0..ancount {
        skip_dns_name(message, &mut offset)?;
        if offset + 10 > message.len() {
            return None;
        }
        let rr_type = u16::from_be_bytes([message[offset], message[offset + 1]]);
        let rr_class = u16::from_be_bytes([message[offset + 2], message[offset + 3]]);
        offset += 8;
        let rdlen = u16::from_be_bytes([message[offset], message[offset + 1]]) as usize;
        offset += 2;
        if offset + rdlen > message.len() {
            return None;
        }
        if rr_type == 16 && rr_class == 3 && rdlen > 1 {
            let txt_len = usize::from(message[offset]);
            if txt_len < rdlen {
                return std::str::from_utf8(&message[offset + 1..offset + 1 + txt_len]).ok();
            }
        }
        offset += rdlen;
    }

    None
}

fn dns_message_slice(payload: &[u8]) -> Option<&[u8]> {
    if payload.len() >= 14 {
        let tcp_len = u16::from_be_bytes([payload[0], payload[1]]) as usize;
        if tcp_len + 2 <= payload.len() && tcp_len >= 12 {
            return payload.get(2..2 + tcp_len);
        }
    }
    Some(payload)
}

fn skip_dns_name(message: &[u8], offset: &mut usize) -> Option<()> {
    let mut jumps = 0usize;
    loop {
        let len = *message.get(*offset)?;
        if len & 0xc0 == 0xc0 {
            *offset = offset.checked_add(2)?;
            return Some(());
        }
        *offset = offset.checked_add(1)?;
        if len == 0 {
            return Some(());
        }
        if len & 0xc0 != 0 || jumps > message.len() {
            return None;
        }
        *offset = offset.checked_add(usize::from(len))?;
        if *offset > message.len() {
            return None;
        }
        jumps += 1;
    }
}

#[cfg(target_os = "linux")]
#[allow(dead_code)]
const TCP_SYN_SIGNATURES_MAP: &str = "tcp_syn_signatures";

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
    if has_sni { "<present>" } else { "" }
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
    let recog_observations = accumulated
        .as_ref()
        .map(recog_auxiliary_observations)
        .unwrap_or_default();
    let os_match = os_matcher::evaluate(OsMatchInput {
        p0f: Some(P0fObservation {
            signature: p0f_signature,
            matched,
        }),
        muonfp: None,
        ja4: ja4_observation.clone(),
        hassh: hassh_observation.clone(),
        recog: recog_observations,
        satori: Vec::new(),
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
    let recog_http = recog_proto_match(accumulated.as_ref(), RecogService::HttpServer);
    let recog_ssh = recog_proto_match(accumulated.as_ref(), RecogService::SshBanner);
    let recog_smb = recog_proto_match(accumulated.as_ref(), RecogService::SmbVersion);
    let recog_ftp = recog_proto_match(accumulated.as_ref(), RecogService::FtpBanner);
    let recog_smtp = recog_proto_match(accumulated.as_ref(), RecogService::SmtpBanner);
    let recog_telnet = recog_proto_match(accumulated.as_ref(), RecogService::TelnetBanner);
    let recog_snmp = recog_proto_match(accumulated.as_ref(), RecogService::SnmpBanner);
    let recog_sip = recog_proto_match(accumulated.as_ref(), RecogService::SipBanner);
    let recog_rdp = recog_proto_match(accumulated.as_ref(), RecogService::RdpBanner);
    let recog_dns = recog_proto_match(accumulated.as_ref(), RecogService::DnsVersion);
    let http_observed = recog_http.is_some();
    let ssh_observed = recog_ssh.is_some();
    let smb_observed = recog_smb.is_some();
    let dns_observed = recog_dns.is_some();
    let sip_observed = recog_sip.is_some();
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
            muonfp: None,
            recog_http,
            recog_ssh,
            recog_smb,
            recog_ftp,
            recog_smtp,
            recog_telnet,
            recog_snmp,
            recog_sip,
            recog_rdp,
            recog_dns,
            recog_ntp: None,
            satori_matches: Vec::new(),
            tcp_observed: true,
            ja4_observed: ja4_observation.is_some(),
            hassh_observed: hassh_observation.is_some(),
            dhcp_observed: false,
            dhcpv6_observed: false,
            http_observed,
            ssh_observed,
            smb_observed,
            dns_observed,
            icmp_observed: false,
            ntp_observed: false,
            sip_observed,
        },
    )
}

fn recog_auxiliary_observations(
    fingerprint: &AccumulatedFingerprint,
) -> Vec<os_matcher::FingerprintObservation> {
    fingerprint
        .recog_matches
        .iter()
        .filter_map(|observation| {
            let os_family = observation.label.os_family.as_ref()?.trim();
            if os_family.is_empty() {
                return None;
            }

            Some(os_matcher::FingerprintObservation {
                signal: recog_signal(observation.service),
                signature: format!("{}:{}", observation.label.source, observation.label.pattern),
                os_family: os_family.to_string(),
                name: observation
                    .label
                    .os_product
                    .clone()
                    .or_else(|| observation.label.product.clone())
                    .or_else(|| observation.label.vendor.clone())
                    .unwrap_or_else(|| "unknown".to_string()),
                version_range: observation
                    .label
                    .os_version
                    .clone()
                    .or_else(|| observation.label.version.clone()),
            })
        })
        .collect()
}

fn recog_signal(service: RecogService) -> FingerprintSignal {
    match service {
        RecogService::HttpServer => FingerprintSignal::RecogHttp,
        RecogService::SshBanner => FingerprintSignal::RecogSsh,
        RecogService::SmbVersion => FingerprintSignal::RecogSmb,
        RecogService::FtpBanner => FingerprintSignal::RecogFtp,
        RecogService::SmtpBanner => FingerprintSignal::RecogSmtp,
        RecogService::TelnetBanner => FingerprintSignal::RecogTelnet,
        RecogService::SnmpBanner => FingerprintSignal::RecogSnmp,
        RecogService::SipBanner => FingerprintSignal::RecogSip,
        RecogService::RdpBanner => FingerprintSignal::RecogRdp,
        RecogService::DnsVersion => FingerprintSignal::RecogDns,
        RecogService::NtpReadvar => FingerprintSignal::RecogNtp,
    }
}

fn recog_proto_match(
    fingerprint: Option<&AccumulatedFingerprint>,
    service: RecogService,
) -> Option<RecogFingerprintMatch> {
    let label = &fingerprint?
        .recog_matches
        .iter()
        .find(|observation| observation.service == service)?
        .label;

    Some(RecogFingerprintMatch {
        product: label
            .product
            .clone()
            .or_else(|| label.hardware_product.clone())
            .or_else(|| label.vendor.clone())
            .unwrap_or_default(),
        version: label
            .version
            .clone()
            .or_else(|| label.os_version.clone())
            .unwrap_or_default(),
        os_family: label.os_family.clone().unwrap_or_default(),
    })
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

// Raw TCP-SYN observation decoded from the tcp_syn_signatures ring buffer. The
// p0f signature string is built from these fields in userspace (see
// crate::p0f_encode) rather than in the eBPF program.
#[allow(dead_code)]
#[derive(Clone, Debug)]
pub struct TcpSynRingRecord {
    pub version: u16,
    pub ip_version: u16,
    pub ttl: u8,
    pub window_scale: u8,
    pub options_len: u8,
    pub payload_class: u8,
    pub source_endpoint: u8,
    pub window_size: u16,
    pub mss: u16,
    pub quirks: u32,
    pub observed_ns: u64,
    pub flow_key: FlowKey,
    pub options_layout: [u8; 32],
}

impl TcpSynRingRecord {
    // Build the canonical p0f signature string from the raw SYN fields. The
    // encoder is allocation-free and ASCII-only, so UTF-8 decoding is total.
    fn p0f_signature(&self) -> String {
        let mut out = [0u8; crate::p0f_encode::P0F_SIGNATURE_MAX_LEN];
        let len = crate::p0f_encode::encode(
            &mut out,
            self.ip_version,
            self.ttl,
            self.window_size,
            self.mss,
            &self.options_layout,
            self.options_len,
            self.window_scale,
            self.payload_class,
            self.quirks,
        ) as usize;
        String::from_utf8_lossy(&out[..len]).into_owned()
    }
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
        record: &TcpSynRingRecord,
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record_with_accumulator(interface_name, record, None)
    }

    fn event_from_ring_record_with_accumulator(
        &self,
        interface_name: &str,
        record: &TcpSynRingRecord,
        accumulator: Option<&FingerprintAccumulator>,
    ) -> Option<FingerprintEvent> {
        if record.version != EVENT_VERSION {
            log::warn!(
                "dropping unsupported tcp syn signature record version {}",
                record.version
            );
            return None;
        }

        let p0f_signature = record.p0f_signature();

        let matched = match self.matcher.match_signature(&p0f_signature) {
            Ok(Some(matched)) => matched,
            Ok(None) => return None,
            Err(error) => {
                log::warn!("failed to match p0f signature {p0f_signature:?}: {error}");
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
            p0f_signature,
            matched,
            accumulated,
        ))
    }

    pub fn event_from_ring_bytes(
        &self,
        interface_name: &str,
        bytes: &[u8],
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record(interface_name, &parse_tcp_syn_ring_record(bytes)?)
    }

    fn event_from_ring_bytes_with_accumulator(
        &self,
        interface_name: &str,
        bytes: &[u8],
        accumulator: Option<&FingerprintAccumulator>,
    ) -> Option<FingerprintEvent> {
        self.event_from_ring_record_with_accumulator(
            interface_name,
            &parse_tcp_syn_ring_record(bytes)?,
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
            .map_mut(TCP_SYN_SIGNATURES_MAP)
            .ok_or_else(|| anyhow::anyhow!("{TCP_SYN_SIGNATURES_MAP} map is missing"))?;
        Ok(Self {
            interface_name: interface_name.into(),
            engine: P0fSignatureEngine::bundled()?,
            ring: aya::maps::RingBuf::try_from(map)?,
        })
    }

    pub fn poll_once(
        &mut self,
        tx: &broadcast::Sender<FingerprintEvent>,
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
            if tx.send(event).is_err() {
                metrics.inc_fingerprint_events_dropped("no_receiver", 1);
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
        tx: broadcast::Sender<FingerprintEvent>,
        gate: Arc<Mutex<FingerprintEventGate>>,
        accumulator: FingerprintAccumulator,
        metrics: Metrics,
    ) -> Result<Self> {
        let map = ebpf
            .take_map(TCP_SYN_SIGNATURES_MAP)
            .ok_or_else(|| anyhow::anyhow!("{TCP_SYN_SIGNATURES_MAP} map is missing"))?;
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
        if let Some(thread) = self.thread.take()
            && thread.join().is_err()
        {
            log::warn!("p0f signature ring thread panicked during shutdown");
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
        tx: &broadcast::Sender<FingerprintEvent>,
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
            if tx.send(event).is_err() {
                metrics.inc_fingerprint_events_dropped("no_receiver", 1);
            } else {
                emitted += 1;
            }
        }

        emitted
    }
}

// Decode a TcpSynSignatureRecord (eBPF #[repr(C)], 104 bytes) from raw ring
// bytes. Field offsets mirror the explicit-padding layout in
// rust/netprobe/ebpf/src/lib.rs; keep them in sync.
#[allow(dead_code)]
fn parse_tcp_syn_ring_record(bytes: &[u8]) -> Option<TcpSynRingRecord> {
    if bytes.len() != TCP_SYN_RING_RECORD_LEN {
        return None;
    }

    let version = u16::from_ne_bytes(bytes.get(0..2)?.try_into().ok()?);
    let ip_version = u16::from_ne_bytes(bytes.get(2..4)?.try_into().ok()?);
    let ttl = *bytes.get(4)?;
    let window_scale = *bytes.get(5)?;
    let options_len = *bytes.get(6)?;
    let payload_class = *bytes.get(7)?;
    let source_endpoint = *bytes.get(8)?;
    // bytes[9] = reserved0 pad
    let window_size = u16::from_ne_bytes(bytes.get(10..12)?.try_into().ok()?);
    let mss = u16::from_ne_bytes(bytes.get(12..14)?.try_into().ok()?);
    // bytes[14..16] = reserved1 pad
    let quirks = u32::from_ne_bytes(bytes.get(16..20)?.try_into().ok()?);
    // bytes[20..24] = reserved2 pad
    let observed_ns = u64::from_ne_bytes(bytes.get(24..32)?.try_into().ok()?);
    let flow_key = parse_flow_key(bytes.get(32..72)?)?;
    let mut options_layout = [0u8; 32];
    options_layout.copy_from_slice(bytes.get(72..104)?);

    Some(TcpSynRingRecord {
        version,
        ip_version,
        ttl,
        window_scale,
        options_len,
        payload_class,
        source_endpoint,
        window_size,
        mss,
        quirks,
        observed_ns,
        flow_key,
        options_layout,
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
        FingerprintSignal::RecogHttp => "recog_http",
        FingerprintSignal::RecogSsh => "recog_ssh",
        FingerprintSignal::RecogSmb => "recog_smb",
        FingerprintSignal::RecogFtp => "recog_ftp",
        FingerprintSignal::RecogSmtp => "recog_smtp",
        FingerprintSignal::RecogTelnet => "recog_telnet",
        FingerprintSignal::RecogSnmp => "recog_snmp",
        FingerprintSignal::RecogSip => "recog_sip",
        FingerprintSignal::RecogRdp => "recog_rdp",
        FingerprintSignal::RecogDns => "recog_dns",
        FingerprintSignal::RecogNtp => "recog_ntp",
        FingerprintSignal::SatoriTcp => "satori_tcp",
        FingerprintSignal::SatoriDhcp => "satori_dhcp",
        FingerprintSignal::SatoriHttp => "satori_http",
        FingerprintSignal::SatoriSsh => "satori_ssh",
        FingerprintSignal::SatoriSmb => "satori_smb",
        FingerprintSignal::SatoriSsl => "satori_ssl",
        FingerprintSignal::SatoriDns => "satori_dns",
        FingerprintSignal::SatoriIcmp => "satori_icmp",
        FingerprintSignal::SatoriNtp => "satori_ntp",
        FingerprintSignal::SatoriSip => "satori_sip",
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
        AF_INET, DpiPayloadContext, EVENT_VERSION, FLOW_ENDPOINT_A, FLOW_ENDPOINT_B,
        FingerprintAccumulator, P0fSignatureEngine, TCP_SYN_RING_RECORD_LEN,
        parse_tcp_syn_ring_record, source_ip_from_flow_key,
    };
    use crate::af_xdp_classifier::FlowKey;
    use crate::proto::netprobe::fingerprint_event;
    use crate::recog::RecogService;
    use std::net::{IpAddr, Ipv4Addr};

    // p0f quirk bits mirrored from the eBPF TCP_SYN_QUIRK_* constants.
    const QUIRK_DF: u32 = 1 << 1;
    const QUIRK_ID_PLUS: u32 = 1 << 2;

    // Canonical p0f signature the Linux fixture fields encode to.
    const LINUX_P0F_SIGNATURE: &str = "4:64:0:1460:29200,10:mss,sok,ts,nop,ws:df,id+:0";

    #[test]
    fn parses_tcp_syn_ring_record_and_encodes_p0f_in_userspace() {
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_B);

        let record = parse_tcp_syn_ring_record(&bytes).unwrap();

        assert_eq!(record.version, EVENT_VERSION);
        assert_eq!(record.observed_ns, 123);
        assert_eq!(record.source_endpoint, FLOW_ENDPOINT_B);
        assert_eq!(
            source_ip_from_flow_key(&record.flow_key, record.source_endpoint),
            Some(IpAddr::V4(Ipv4Addr::new(198, 51, 100, 20)))
        );
        // The p0f signature is built in userspace from the raw SYN fields.
        assert_eq!(record.p0f_signature(), LINUX_P0F_SIGNATURE);
    }

    #[test]
    fn rejects_wrong_length_tcp_syn_ring_record() {
        assert!(parse_tcp_syn_ring_record(&[0; TCP_SYN_RING_RECORD_LEN - 1]).is_none());
        assert!(parse_tcp_syn_ring_record(&[0; TCP_SYN_RING_RECORD_LEN + 1]).is_none());
    }

    #[test]
    fn builds_license_clean_event_from_tcp_syn_ring_record() {
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_B);
        let engine = P0fSignatureEngine::bundled().unwrap();

        let event = engine.event_from_ring_bytes("eth0", &bytes).unwrap();

        assert_eq!(event.ip, "198.51.100.20");
        assert_eq!(event.interface_name, "eth0");
        assert_eq!(event.observed_at_unix_nano, 123);
        let Some(fingerprint_event::Evidence::LicenseClean(fingerprint)) = event.evidence else {
            panic!("expected license-clean fingerprint");
        };
        assert_eq!(fingerprint.p0f_signature, LINUX_P0F_SIGNATURE);
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
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_B);
        let record = parse_tcp_syn_ring_record(&bytes).unwrap();
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
        assert!(fingerprint.tcp_observed);
        assert!(fingerprint.ja4_observed);
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
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_B);
        let record = parse_tcp_syn_ring_record(&bytes).unwrap();
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
    fn enriches_p0f_ring_event_with_accumulated_recog_ssh() {
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_B);
        let record = parse_tcp_syn_ring_record(&bytes).unwrap();
        let accumulator = FingerprintAccumulator::default();
        accumulator.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key: record.flow_key,
                source_port: 22,
                destination_port: 51_234,
                transport_protocol: "tcp",
            },
            b"SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.10\r\n",
            124,
        );
        let engine = P0fSignatureEngine::bundled().unwrap();

        let event = engine
            .event_from_ring_record_with_accumulator("eth0", &record, Some(&accumulator))
            .unwrap();

        let Some(fingerprint_event::Evidence::LicenseClean(fingerprint)) = event.evidence else {
            panic!("expected license-clean fingerprint");
        };
        assert_eq!(fingerprint.agreement_count, 2);
        assert!(fingerprint.tcp_observed);
        assert!(fingerprint.ssh_observed);
        assert_eq!(
            fingerprint
                .recog_ssh
                .as_ref()
                .map(|matched| matched.product.as_str()),
            Some("OpenSSH")
        );
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
    fn accumulates_recog_http_server_match_without_payload_bytes() {
        let flow_key = fixture_flow_key(80, 49_152);
        let accumulator = FingerprintAccumulator::default();

        accumulator.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key,
                source_port: 80,
                destination_port: 49_152,
                transport_protocol: "tcp",
            },
            b"HTTP/1.1 200 OK\r\nServer: Apache/2.4.58 (Ubuntu)\r\nContent-Length: 0\r\n\r\n",
            124,
        );

        let snapshot = accumulator
            .snapshot(&flow_key, 124)
            .expect("expected accumulated Recog match");
        let matched = snapshot
            .recog_matches
            .iter()
            .find(|matched| matched.service == RecogService::HttpServer)
            .expect("expected HTTP-server Recog match");

        assert_eq!(matched.label.product.as_deref(), Some("HTTPD"));
        assert_eq!(matched.label.version.as_deref(), Some("2.4.58"));
        assert!(!format!("{snapshot:?}").contains("HTTP/1.1 200 OK"));
    }

    #[test]
    fn accumulates_recog_ssh_and_ftp_banner_matches() {
        let ssh_flow_key = fixture_flow_key(22, 49_152);
        let ftp_flow_key = fixture_flow_key(21, 49_153);
        let accumulator = FingerprintAccumulator::default();

        accumulator.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key: ssh_flow_key,
                source_port: 22,
                destination_port: 49_152,
                transport_protocol: "tcp",
            },
            b"SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.10\r\n",
            124,
        );
        accumulator.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key: ftp_flow_key,
                source_port: 21,
                destination_port: 49_153,
                transport_protocol: "tcp",
            },
            b"220 foo.bar Microsoft FTP Service (Version 5.0).\r\n",
            124,
        );

        let ssh_snapshot = accumulator
            .snapshot(&ssh_flow_key, 124)
            .expect("expected SSH Recog match");
        let ftp_snapshot = accumulator
            .snapshot(&ftp_flow_key, 124)
            .expect("expected FTP Recog match");

        assert_eq!(
            ssh_snapshot
                .recog_matches
                .iter()
                .find(|matched| matched.service == RecogService::SshBanner)
                .and_then(|matched| matched.label.product.as_deref()),
            Some("OpenSSH")
        );
        assert_eq!(
            ftp_snapshot
                .recog_matches
                .iter()
                .find(|matched| matched.service == RecogService::FtpBanner)
                .and_then(|matched| matched.label.os_family.as_deref()),
            Some("Windows")
        );
    }

    #[test]
    fn accumulates_recog_text_banner_services() {
        let accumulator = FingerprintAccumulator::default();
        let cases = [
            (
                fixture_flow_key(23, 49_154),
                DpiPayloadContext {
                    flow_key: fixture_flow_key(23, 49_154),
                    source_port: 23,
                    destination_port: 49_154,
                    transport_protocol: "tcp",
                },
                b"Password required, but none set\r\n".as_slice(),
                RecogService::TelnetBanner,
                Some("Cisco"),
            ),
            (
                fixture_flow_key(445, 49_155),
                DpiPayloadContext {
                    flow_key: fixture_flow_key(445, 49_155),
                    source_port: 445,
                    destination_port: 49_155,
                    transport_protocol: "tcp",
                },
                b"Samba 4.13.17\r\n".as_slice(),
                RecogService::SmbVersion,
                Some("Samba"),
            ),
            (
                fixture_udp_flow_key(161, 49_156),
                DpiPayloadContext {
                    flow_key: fixture_udp_flow_key(161, 49_156),
                    source_port: 161,
                    destination_port: 49_156,
                    transport_protocol: "udp",
                },
                b"3Com IntelliJack NJ220\n".as_slice(),
                RecogService::SnmpBanner,
                Some("3Com"),
            ),
            (
                fixture_udp_flow_key(5060, 49_157),
                DpiPayloadContext {
                    flow_key: fixture_udp_flow_key(5060, 49_157),
                    source_port: 5060,
                    destination_port: 49_157,
                    transport_protocol: "udp",
                },
                b"SIP/2.0 200 OK\r\nServer: Cisco-SIPGateway/IOS-15.2.4.M3\r\n\r\n".as_slice(),
                RecogService::SipBanner,
                Some("Cisco"),
            ),
        ];

        for (flow_key, context, payload, service, expected_vendor) in cases {
            accumulator.observe_dpi_payload_with_context(context, payload, 124);
            let snapshot = accumulator
                .snapshot(&flow_key, 124)
                .expect("expected Recog match");
            assert_eq!(
                snapshot
                    .recog_matches
                    .iter()
                    .find(|matched| matched.service == service)
                    .and_then(|matched| matched.label.vendor.as_deref()),
                expected_vendor
            );
        }
    }

    #[test]
    fn accumulates_recog_dns_version_bind_match() {
        let flow_key = fixture_udp_flow_key(53, 49_158);
        let accumulator = FingerprintAccumulator::default();

        accumulator.observe_dpi_payload_with_context(
            DpiPayloadContext {
                flow_key,
                source_port: 53,
                destination_port: 49_158,
                transport_protocol: "udp",
            },
            &dns_version_bind_response("9.9.4-RedHat-9.9.4-38.el7_3.3"),
            124,
        );

        let snapshot = accumulator
            .snapshot(&flow_key, 124)
            .expect("expected DNS Recog match");
        let matched = snapshot
            .recog_matches
            .iter()
            .find(|matched| matched.service == RecogService::DnsVersion)
            .expect("expected DNS version Recog match");

        assert_eq!(matched.label.product.as_deref(), Some("BIND"));
        assert_eq!(matched.label.version.as_deref(), Some("9.9.4"));
    }

    #[test]
    fn source_endpoint_a_resolves_to_endpoint_a_addr() {
        let bytes = tcp_syn_record_bytes(FLOW_ENDPOINT_A);
        let record = parse_tcp_syn_ring_record(&bytes).unwrap();
        assert_eq!(
            source_ip_from_flow_key(&record.flow_key, record.source_endpoint),
            Some(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10)))
        );
    }

    // Builds a TcpSynSignatureRecord (eBPF #[repr(C)], 104 bytes, explicit
    // padding) whose raw SYN fields encode to LINUX_P0F_SIGNATURE. Offsets mirror
    // parse_tcp_syn_ring_record / the eBPF struct layout.
    fn tcp_syn_record_bytes(source_endpoint: u8) -> Vec<u8> {
        let mut bytes = vec![0u8; TCP_SYN_RING_RECORD_LEN];
        bytes[0..2].copy_from_slice(&EVENT_VERSION.to_ne_bytes()); // version
        bytes[2..4].copy_from_slice(&4u16.to_ne_bytes()); // ip_version
        bytes[4] = 64; // ttl
        bytes[5] = 10; // window_scale
        bytes[6] = 5; // options_len
        bytes[7] = 0; // payload_class (empty)
        bytes[8] = source_endpoint;
        bytes[10..12].copy_from_slice(&29_200u16.to_ne_bytes()); // window_size
        bytes[12..14].copy_from_slice(&1_460u16.to_ne_bytes()); // mss
        bytes[16..20].copy_from_slice(&(QUIRK_DF | QUIRK_ID_PLUS).to_ne_bytes()); // quirks
        bytes[24..32].copy_from_slice(&123u64.to_ne_bytes()); // observed_ns
        write_flow_key(&mut bytes[32..72], fixture_flow_key(443, 51_234));
        // options_layout: mss(2),sok(4),ts(8),nop(1),ws(3)
        bytes[72..77].copy_from_slice(&[2, 4, 8, 1, 3]);
        bytes
    }

    fn fixture_flow_key(endpoint_a_port: u16, endpoint_b_port: u16) -> FlowKey {
        FlowKey {
            address_family: AF_INET,
            transport_protocol: 6,
            endpoint_a_port,
            endpoint_b_port,
            endpoint_a_addr: ipv4_addr([192, 0, 2, 10]),
            endpoint_b_addr: ipv4_addr([198, 51, 100, 20]),
        }
    }

    fn fixture_udp_flow_key(endpoint_a_port: u16, endpoint_b_port: u16) -> FlowKey {
        FlowKey {
            address_family: AF_INET,
            transport_protocol: 17,
            endpoint_a_port,
            endpoint_b_port,
            endpoint_a_addr: ipv4_addr([192, 0, 2, 10]),
            endpoint_b_addr: ipv4_addr([198, 51, 100, 20]),
        }
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

    fn dns_version_bind_response(version: &str) -> Vec<u8> {
        let mut message = Vec::new();
        message.extend_from_slice(&0x1234u16.to_be_bytes());
        message.extend_from_slice(&0x8180u16.to_be_bytes());
        message.extend_from_slice(&1u16.to_be_bytes());
        message.extend_from_slice(&1u16.to_be_bytes());
        message.extend_from_slice(&0u16.to_be_bytes());
        message.extend_from_slice(&0u16.to_be_bytes());
        message.extend_from_slice(&[
            7, b'v', b'e', b'r', b's', b'i', b'o', b'n', 4, b'b', b'i', b'n', b'd', 0,
        ]);
        message.extend_from_slice(&16u16.to_be_bytes());
        message.extend_from_slice(&3u16.to_be_bytes());
        message.extend_from_slice(&[0xc0, 0x0c]);
        message.extend_from_slice(&16u16.to_be_bytes());
        message.extend_from_slice(&3u16.to_be_bytes());
        message.extend_from_slice(&0u32.to_be_bytes());
        let txt_len = version.len().min(255);
        let rdlen = txt_len + 1;
        message.extend_from_slice(&(rdlen as u16).to_be_bytes());
        message.push(txt_len as u8);
        message.extend_from_slice(&version.as_bytes()[..txt_len]);
        message
    }
}

#[cfg(all(test, feature = "remote-capture"))]
mod tests {
    use super::{FingerprintEngine, header_value, redact_sni_presence};
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
