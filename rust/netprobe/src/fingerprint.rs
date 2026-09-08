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

use crate::hassh;
use crate::proto::netprobe::{
    FingerprintDisagreement, FingerprintEvent, FingerprintMatch, LicenseCleanFingerprint,
    OsMatch as ProtoOsMatch, P0fFingerprintMatch, RecogFingerprintMatch, fingerprint_event,
};
use crate::recog::{self, RecogLabel, RecogService};
use crate::{
    af_xdp_classifier::FlowKey,
    os_matcher::{self, FingerprintSignal, OsMatchInput, P0fObservation, SignalDisagreement},
    p0f_matcher::{P0fMatch, P0fMatcher},
};
#[cfg(target_os = "linux")]
use crate::{metrics::Metrics, runtime_config::FingerprintEventGate};
#[cfg(target_os = "linux")]
use anyhow::Result;

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
