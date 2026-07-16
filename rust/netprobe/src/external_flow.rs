use std::{
    net::{IpAddr, Ipv4Addr, Ipv6Addr},
    sync::{Arc, RwLock},
};

use crate::{
    af_xdp_classifier::{FlowKey, canonical_flow_key, transport_protocol},
    proto::netprobe::{ExternalFlowRecord, FlowAttributionEvent},
};

pub const EXTERNAL_NETFLOW_SOURCE: &str = "external_netflow";

const DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS: u32 = 120_000;

#[derive(Debug, Clone)]
pub struct ExternalFlowMatcher {
    match_window_ms: u32,
    attribution: std::collections::HashMap<FlowKey, FlowAttributionEvent>,
}

#[derive(Debug, Clone, PartialEq)]
// Matched is the common ingest path; boxing it to shrink the empty variants
// would add an allocation on the hot path.
#[allow(clippy::large_enum_variant)]
pub enum ExternalFlowIngest {
    Matched(FlowAttributionEvent),
    Unmatched,
    Invalid,
}

#[derive(Debug, Clone)]
pub struct SharedExternalFlowMatcher {
    inner: Arc<RwLock<ExternalFlowMatcher>>,
}

impl SharedExternalFlowMatcher {
    pub fn new(match_window_ms: u32) -> Self {
        Self {
            inner: Arc::new(RwLock::new(ExternalFlowMatcher::new(match_window_ms))),
        }
    }

    pub fn set_match_window_ms(&self, match_window_ms: u32) {
        self.inner
            .write()
            .expect("external flow matcher lock poisoned")
            .set_match_window_ms(match_window_ms);
    }

    #[allow(dead_code)]
    pub fn observe_attribution(&self, event: &FlowAttributionEvent) {
        self.inner
            .write()
            .expect("external flow matcher lock poisoned")
            .observe_attribution(event);
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn observe_attribution_key(&self, key: FlowKey, event: &FlowAttributionEvent) {
        self.inner
            .write()
            .expect("external flow matcher lock poisoned")
            .observe_attribution_key(key, event);
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn remove_flow(&self, flow: &FlowKey) {
        self.inner
            .write()
            .expect("external flow matcher lock poisoned")
            .remove_flow(flow);
    }

    pub fn ingest(&self, record: &ExternalFlowRecord, now_unix_nano: i64) -> ExternalFlowIngest {
        self.inner
            .read()
            .expect("external flow matcher lock poisoned")
            .ingest(record, now_unix_nano)
    }
}

impl ExternalFlowMatcher {
    pub fn new(match_window_ms: u32) -> Self {
        Self {
            match_window_ms: effective_match_window_ms(match_window_ms),
            attribution: std::collections::HashMap::new(),
        }
    }

    pub fn set_match_window_ms(&mut self, match_window_ms: u32) {
        self.match_window_ms = effective_match_window_ms(match_window_ms);
    }

    #[allow(dead_code)]
    pub fn observe_attribution(&mut self, event: &FlowAttributionEvent) {
        let Some(key) = flow_key_from_attribution_event(event) else {
            return;
        };

        self.observe_attribution_key(key, event);
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn observe_attribution_key(&mut self, key: FlowKey, event: &FlowAttributionEvent) {
        self.attribution.insert(key, event.clone());
    }

    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    pub fn remove_flow(&mut self, flow: &FlowKey) {
        self.attribution.remove(flow);
    }

    pub fn ingest(&self, record: &ExternalFlowRecord, now_unix_nano: i64) -> ExternalFlowIngest {
        let Some(key) = flow_key_from_external_record(record) else {
            return ExternalFlowIngest::Invalid;
        };
        let Some(event) = self.attribution.get(&key) else {
            return ExternalFlowIngest::Unmatched;
        };
        if !within_match_window(record, event, now_unix_nano, self.match_window_ms) {
            return ExternalFlowIngest::Unmatched;
        }

        let mut matched = event.clone();
        matched.source = EXTERNAL_NETFLOW_SOURCE.to_string();
        matched.external_flow_id = record.external_flow_id;
        ExternalFlowIngest::Matched(matched)
    }
}

pub fn default_external_flow_match_window_ms() -> u32 {
    DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS
}

fn effective_match_window_ms(configured: u32) -> u32 {
    if configured == 0 {
        DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS
    } else {
        configured
    }
}

#[allow(dead_code)]
fn flow_key_from_attribution_event(event: &FlowAttributionEvent) -> Option<FlowKey> {
    canonical_flow_key(
        event.local_ip.parse().ok()?,
        event.remote_ip.parse().ok()?,
        event.local_port.try_into().ok()?,
        event.remote_port.try_into().ok()?,
        transport_protocol(event.transport_protocol.as_str())?,
    )
}

fn flow_key_from_external_record(record: &ExternalFlowRecord) -> Option<FlowKey> {
    canonical_flow_key(
        ip_addr(&record.source_ip)?,
        ip_addr(&record.destination_ip)?,
        record.source_port.try_into().ok()?,
        record.destination_port.try_into().ok()?,
        external_transport_protocol(record)?,
    )
}

fn external_transport_protocol(record: &ExternalFlowRecord) -> Option<u16> {
    match record.ip_protocol {
        1 => Some(1),
        6 => Some(6),
        17 => Some(17),
        58 => Some(58),
        0 => transport_protocol(record.transport_protocol.to_ascii_lowercase().as_str()),
        _ => None,
    }
}

fn ip_addr(bytes: &[u8]) -> Option<IpAddr> {
    match bytes.len() {
        4 => Some(IpAddr::V4(Ipv4Addr::new(
            bytes[0], bytes[1], bytes[2], bytes[3],
        ))),
        16 => Some(IpAddr::V6(Ipv6Addr::from(
            <[u8; 16]>::try_from(bytes).ok()?,
        ))),
        _ => None,
    }
}

fn within_match_window(
    record: &ExternalFlowRecord,
    event: &FlowAttributionEvent,
    now_unix_nano: i64,
    match_window_ms: u32,
) -> bool {
    if event.observed_at_unix_nano <= 0 {
        return true;
    }

    let observed = external_observed_unix_nano(record).unwrap_or(now_unix_nano);
    let delta = observed.abs_diff(event.observed_at_unix_nano);
    delta <= u64::from(match_window_ms) * 1_000_000
}

fn external_observed_unix_nano(record: &ExternalFlowRecord) -> Option<i64> {
    let value = if record.time_flow_end_ns > 0 {
        record.time_flow_end_ns
    } else if record.time_flow_start_ns > 0 {
        record.time_flow_start_ns
    } else {
        return None;
    };

    i64::try_from(value).ok()
}

#[cfg(test)]
mod tests {
    use super::{
        DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS, EXTERNAL_NETFLOW_SOURCE, ExternalFlowIngest,
        ExternalFlowMatcher,
    };
    use crate::proto::netprobe::{ExternalFlowRecord, FlowAttributionEvent};

    #[test]
    fn matches_external_flow_by_canonical_five_tuple() {
        let mut matcher = ExternalFlowMatcher::new(0);
        matcher.observe_attribution(&attribution_event());

        let result = matcher.ingest(&external_flow_record(), 123_456);

        let ExternalFlowIngest::Matched(event) = result else {
            panic!("expected matched external flow");
        };
        assert_eq!(event.pid, 123);
        assert_eq!(event.source, EXTERNAL_NETFLOW_SOURCE);
        assert_eq!(event.external_flow_id, 42);
    }

    #[test]
    fn rejects_external_flow_outside_match_window() {
        let mut matcher = ExternalFlowMatcher::new(1);
        matcher.observe_attribution(&attribution_event());
        let mut record = external_flow_record();
        record.time_flow_end_ns = 10_000_000;

        assert_eq!(
            matcher.ingest(&record, 10_000_000),
            ExternalFlowIngest::Unmatched
        );
    }

    #[test]
    fn rejects_invalid_external_flow_record() {
        let matcher = ExternalFlowMatcher::new(DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS);

        assert_eq!(
            matcher.ingest(&ExternalFlowRecord::default(), 123),
            ExternalFlowIngest::Invalid
        );
    }

    #[test]
    fn matched_event_carries_attribution_redacted_cmdline() {
        // The matcher passes the cached FlowAttributionEvent through
        // verbatim on Matched. §20.15 enforcement lives at the producer
        // site (`attribution::flow_attribution_event`), so by the time the
        // attribution event lands in the matcher cache it has already been
        // joined + capped. This test pins the contract: whatever joined
        // payload the matcher cached is exactly what it emits on Matched
        // (no double-truncation, no re-shaping into multiple elements).
        let mut matcher = ExternalFlowMatcher::new(0);
        let capped_payload = "/usr/bin/curl [redacted 2 arg(s)]".to_string();
        let mut attribution = attribution_event();
        attribution.redacted_cmdline = vec![capped_payload.clone()];
        matcher.observe_attribution(&attribution);

        let ExternalFlowIngest::Matched(event) = matcher.ingest(&external_flow_record(), 123_456)
        else {
            panic!("expected matched external flow");
        };

        assert_eq!(event.redacted_cmdline, vec![capped_payload]);
    }

    #[test]
    fn matches_external_icmp_flow_by_ip_tuple() {
        let mut matcher = ExternalFlowMatcher::new(0);
        let mut attribution = attribution_event();
        attribution.local_port = 0;
        attribution.remote_port = 0;
        attribution.transport_protocol = "icmp".to_string();
        matcher.observe_attribution(&attribution);

        let mut record = external_flow_record();
        record.source_port = 0;
        record.destination_port = 0;
        record.transport_protocol = "icmp".to_string();
        record.ip_protocol = 1;

        assert!(matches!(
            matcher.ingest(&record, 123_456),
            ExternalFlowIngest::Matched(_)
        ));
    }

    fn attribution_event() -> FlowAttributionEvent {
        FlowAttributionEvent {
            local_ip: "192.0.2.10".to_string(),
            local_port: 49_152,
            remote_ip: "198.51.100.20".to_string(),
            remote_port: 443,
            transport_protocol: "tcp".to_string(),
            pid: 123,
            tgid: 123,
            observed_at_unix_nano: 123_456,
            ..Default::default()
        }
    }

    fn external_flow_record() -> ExternalFlowRecord {
        ExternalFlowRecord {
            external_flow_id: 42,
            source_ip: vec![198, 51, 100, 20],
            destination_ip: vec![192, 0, 2, 10],
            source_port: 443,
            destination_port: 49_152,
            transport_protocol: "tcp".to_string(),
            time_flow_end_ns: 123_456,
            bytes: 1024,
            packets: 7,
            ..Default::default()
        }
    }
}
