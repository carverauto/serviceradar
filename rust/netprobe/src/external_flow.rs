use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use crate::{
    af_xdp_classifier::{canonical_flow_key, transport_protocol, FlowKey},
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
pub enum ExternalFlowIngest {
    Matched(FlowAttributionEvent),
    Unmatched,
    Invalid,
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

    pub fn observe_attribution(&mut self, event: &FlowAttributionEvent) {
        let Some(key) = flow_key_from_attribution_event(event) else {
            return;
        };

        self.attribution.insert(key, event.clone());
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
        6 => Some(6),
        17 => Some(17),
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
        ExternalFlowIngest, ExternalFlowMatcher, DEFAULT_EXTERNAL_FLOW_MATCH_WINDOW_MS,
        EXTERNAL_NETFLOW_SOURCE,
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
