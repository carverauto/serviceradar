use crate::config::ListenerConfig;
use crate::error::GetCurrentTimeError;
use crate::flowpb::{AttributedFlowMessage, FlowMessage};
use crate::host_slice::HostSliceRouter;
use crate::metrics::{ListenerMetrics, SubjectDropRegistry};
use crate::netflow::NetflowHandler;
use crate::publisher::OutboundFlow;
use crate::sflow::SflowHandler;
use anyhow::Result;
use log::{error, info, warn};
use prost::Message;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Instant;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

/// Check if a flow message is valid (not degenerate).
pub fn is_valid_flow(msg: &FlowMessage) -> bool {
    msg.bytes > 0 || msg.packets > 0
}

/// Get current time in nanoseconds since UNIX epoch.
pub fn get_current_time_ns() -> Result<u64, GetCurrentTimeError> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(GetCurrentTimeError::SystemTimeError)?;
    u64::try_from(duration.as_nanos()).map_err(GetCurrentTimeError::TryFromIntError)
}

/// Filter degenerate flows and update metrics counters.
/// Returns only valid flows (bytes > 0 or packets > 0).
pub fn filter_and_track_flows(
    flows: Vec<FlowMessage>,
    peer: SocketAddr,
    metrics: &ListenerMetrics,
) -> Vec<FlowMessage> {
    let (valid, invalid): (Vec<_>, Vec<_>) = flows.into_iter().partition(is_valid_flow);

    if !invalid.is_empty() {
        warn!(
            "Dropped {} degenerate flow record(s) from {} (0 bytes, 0 packets)",
            invalid.len(),
            peer
        );
        metrics
            .flows_dropped
            .fetch_add(invalid.len() as u64, Ordering::Relaxed);
    }

    metrics
        .flows_converted
        .fetch_add(valid.len() as u64, Ordering::Relaxed);

    valid
}

/// Serialize a FlowMessage to protobuf bytes for downstream consumers.
pub fn flow_to_bytes(msg: &FlowMessage) -> Vec<u8> {
    msg.encode_to_vec()
}

/// Serialize a host-slice message for the attribution joiner path.
pub fn host_slice_flow_to_bytes(msg: &FlowMessage, agent_id: &str, partition: &str) -> Vec<u8> {
    AttributedFlowMessage {
        event_type: "host_slice_flow".to_string(),
        flow: Some(msg.clone()),
        attribution: None,
        agent_id: agent_id.to_string(),
        partition: partition.to_string(),
    }
    .encode_to_vec()
}

pub trait FlowHandler: Send + Sync {
    /// Parse a raw UDP datagram and return zero or more FlowMessages.
    fn parse_datagram(&self, buf: &[u8], len: usize, peer: SocketAddr) -> Vec<FlowMessage>;

    /// Return the protocol name for logging/metrics.
    fn protocol_name(&self) -> &'static str;
}

pub struct Listener {
    handler: Box<dyn FlowHandler>,
    socket: UdpSocket,
    buffer_size: usize,
    output: FlowOutput,
}

/// The shared bounded publication path for UDP and authenticated IPFIX.
#[derive(Clone)]
pub struct FlowOutput {
    tx: mpsc::Sender<OutboundFlow>,
    subject: String,
    host_slice_router: Arc<HostSliceRouter>,
    pub metrics: Arc<ListenerMetrics>,
    subject_drops: Arc<SubjectDropRegistry>,
}

impl Listener {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        handler: Box<dyn FlowHandler>,
        socket: UdpSocket,
        buffer_size: usize,
        subject: String,
        host_slice_router: Arc<HostSliceRouter>,
        tx: mpsc::Sender<OutboundFlow>,
        metrics: Arc<ListenerMetrics>,
        subject_drops: Arc<SubjectDropRegistry>,
    ) -> Self {
        Self {
            handler,
            socket,
            buffer_size,
            output: FlowOutput::new(subject, host_slice_router, tx, metrics, subject_drops),
        }
    }

    pub async fn run(self) -> Result<()> {
        let mut buf = vec![0u8; self.buffer_size];
        let protocol = self.handler.protocol_name();
        let addr = self.socket.local_addr()?;

        info!("{} listener running on {}", protocol, addr);

        loop {
            match self.socket.recv_from(&mut buf).await {
                Ok((len, peer_addr)) => {
                    self.output
                        .metrics
                        .packets_received
                        .fetch_add(1, Ordering::Relaxed);
                    let messages = self.handler.parse_datagram(&buf[..len], len, peer_addr);

                    self.output.publish(protocol, messages)?;
                }
                Err(e) => {
                    error!("[{}] Error receiving UDP packet: {}", protocol, e);
                }
            }
        }
    }
}

impl FlowOutput {
    pub fn new(
        subject: String,
        host_slice_router: Arc<HostSliceRouter>,
        tx: mpsc::Sender<OutboundFlow>,
        metrics: Arc<ListenerMetrics>,
        subject_drops: Arc<SubjectDropRegistry>,
    ) -> Self {
        Self {
            subject,
            host_slice_router,
            tx,
            metrics,
            subject_drops,
        }
    }

    pub fn publish(&self, protocol: &str, messages: Vec<FlowMessage>) -> Result<()> {
        for flow_msg in messages {
            let encoded = flow_to_bytes(&flow_msg);

            if !self.publish_encoded(protocol, self.subject.clone(), encoded.clone())? {
                continue;
            }

            for target in self.host_slice_router.targets_for_flow(&flow_msg) {
                let host_slice_encoded = host_slice_flow_to_bytes(
                    &flow_msg,
                    target.agent_id.as_ref(),
                    target.partition.as_ref(),
                );
                if !self.publish_encoded(
                    protocol,
                    target.subject.to_string(),
                    host_slice_encoded,
                )? {
                    break;
                }
            }
        }
        Ok(())
    }

    fn publish_encoded(&self, protocol: &str, subject: String, encoded: Vec<u8>) -> Result<bool> {
        // Stamp ingress at transport accept so publisher never-attempted TTL bounds
        // hold time across both channel layers.
        match self.tx.try_send((subject, encoded, Instant::now())) {
            Ok(_) => Ok(true),
            Err(mpsc::error::TrySendError::Full((dropped_subject, _, _))) => {
                warn!(
                    "[{}] Publisher channel full, dropping flow message for subject '{}'",
                    protocol, dropped_subject
                );
                // `channel_full_drops` is kept distinct from `flows_dropped`
                // (which still counts degenerate flows pre-channel) so
                // operators can tell parser-side filtering from backpressure.
                self.metrics
                    .channel_full_drops
                    .fetch_add(1, Ordering::Relaxed);
                self.subject_drops.record_drop(&dropped_subject);

                Ok(false)
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                error!("[{}] Publisher channel closed, stopping listener", protocol);
                Err(anyhow::anyhow!("Publisher channel closed"))
            }
        }
    }
}

/// Construct the appropriate FlowHandler from a ListenerConfig variant.
pub fn build_handler(
    config: &ListenerConfig,
    metrics: Arc<ListenerMetrics>,
) -> Box<dyn FlowHandler> {
    match config {
        ListenerConfig::Sflow {
            max_samples_per_datagram,
            ..
        } => Box::new(SflowHandler::new(*max_samples_per_datagram, metrics)),
        ListenerConfig::IpfixTls { .. } => unreachable!("TLS listener owns session-local parsers"),
        ListenerConfig::Netflow {
            allow_unauthenticated_templates,
            max_templates,
            max_template_fields,
            pending_flows,
            default_sampling_rate,
            sampling_rate_overrides,
            max_sources,
            ..
        } => Box::new(UdpNetflowHandler {
            allow_templates: *allow_unauthenticated_templates,
            metrics: Arc::clone(&metrics),
            parser: NetflowHandler::new(
                *max_templates,
                *max_template_fields,
                pending_flows.as_ref(),
                *default_sampling_rate,
                sampling_rate_overrides.clone(),
                *max_sources,
                metrics,
            ),
        }),
    }
}

struct UdpNetflowHandler {
    parser: NetflowHandler,
    allow_templates: bool,
    metrics: Arc<ListenerMetrics>,
}

impl FlowHandler for UdpNetflowHandler {
    fn parse_datagram(&self, buf: &[u8], len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
        // A legacy packet prefix must not hide a trailing template packet from
        // netflow_parser's multi-packet iterator. Validate every packet boundary.
        let sflow = buf.starts_with(&[0, 0, 0, 5]);
        if !self.allow_templates && !sflow && !legacy_only_datagram(buf) {
            self.metrics
                .udp_template_rejections
                .fetch_add(1, Ordering::Relaxed);
            return Vec::new();
        }
        self.parser.parse_datagram(buf, len, peer)
    }
    fn protocol_name(&self) -> &'static str {
        "netflow"
    }
}

fn legacy_only_datagram(mut bytes: &[u8]) -> bool {
    if bytes.is_empty() {
        return false;
    }
    while !bytes.is_empty() {
        if bytes.len() < 24 {
            return false;
        }
        let version = u16::from_be_bytes([bytes[0], bytes[1]]);
        let count = usize::from(u16::from_be_bytes([bytes[2], bytes[3]]));
        // Per-PDU caps match the locked parser (v5: 30, v7: 28). A jumbo
        // datagram is only legitimate as concatenated individually bounded
        // PDUs, never as one PDU carrying more records than the parser
        // accepts.
        let (record_size, max_count): (usize, usize) = match version {
            5 => (48, 30),
            7 => (52, 28),
            _ => return false,
        };
        if count == 0 || count > max_count {
            return false;
        }
        let Some(size) = record_size
            .checked_mul(count)
            .and_then(|payload| payload.checked_add(24))
        else {
            return false;
        };
        let Some(remaining) = bytes.get(size..) else {
            return false;
        };
        bytes = remaining;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, HostNetworkVisibilityStatus, HostSliceConfig, ListenerConfig};
    use std::net::{IpAddr, Ipv4Addr};
    use tokio::time::{Duration, sleep, timeout};

    #[tokio::test]
    async fn udp_secure_defaults_reject_template_packets_before_publication() {
        use crate::test_packets::{ipfix, legacy};
        for insecure in [false, true] {
            let config: ListenerConfig = serde_json::from_value(serde_json::json!({
                "protocol": "netflow", "listen_addr": "127.0.0.1:0", "subject": "flows.raw.netflow",
                "allow_unauthenticated_templates": insecure
            }))
            .unwrap();
            let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let addr = socket.local_addr().unwrap();
            let metrics = Arc::new(ListenerMetrics::new("netflow", addr.to_string()));
            let (tx, mut rx) = mpsc::channel(16);
            let listener = Listener::new(
                build_handler(&config, Arc::clone(&metrics)),
                socket,
                65536,
                "flows.raw.netflow".into(),
                Arc::new(HostSliceRouter::default()),
                tx,
                Arc::clone(&metrics),
                Arc::new(SubjectDropRegistry::new()),
            );
            let task = tokio::spawn(listener.run());
            let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let template = ipfix(1, Some(&[(1, 4)]), &999u32.to_be_bytes());
            let mut prefixed = legacy(5);
            prefixed.extend_from_slice(&template);
            // One valid v9 template plus flow, invented from the wire layout.
            let mut v9 = vec![0, 9, 0, 1];
            for value in [1000u32, 1_893_456_000, 1, 1] {
                v9.extend(value.to_be_bytes());
            }
            v9.extend_from_slice(&[0, 0, 0, 12, 1, 0, 0, 1, 0, 1, 0, 4, 1, 0, 0, 8]);
            v9.extend(999u32.to_be_bytes());
            for (packet, count) in [(&template, 1), (&prefixed, 2), (&v9, 1)] {
                sender.send_to(packet, addr).await.unwrap();
                if insecure {
                    let mut values = Vec::new();
                    for _ in 0..count {
                        let (_, bytes, _) = timeout(Duration::from_secs(3), rx.recv())
                            .await
                            .unwrap()
                            .unwrap();
                        values.push(FlowMessage::decode(bytes.as_slice()).unwrap().bytes);
                    }
                    assert!(values.contains(&999));
                }
            }
            if !insecure {
                timeout(Duration::from_secs(3), async {
                    while metrics.udp_template_rejections.load(Ordering::Relaxed) != 3 {
                        sleep(Duration::from_millis(5)).await;
                    }
                })
                .await
                .expect("default UDP listener admitted a template packet");
                assert_eq!(metrics.source_count.load(Ordering::Relaxed), 0);
                assert!(rx.try_recv().is_err());
            }
            // Template-free v5 and concatenated v5 packets remain valid.
            for (packet, expected) in [(legacy(5), 1), ([legacy(5), legacy(5)].concat(), 2)] {
                sender.send_to(&packet, addr).await.unwrap();
                for _ in 0..expected {
                    let (_, bytes, _) = timeout(Duration::from_secs(3), rx.recv())
                        .await
                        .unwrap()
                        .unwrap();
                    assert_eq!(FlowMessage::decode(bytes.as_slice()).unwrap().bytes, 111);
                }
            }
            // v7 is structurally legacy (never template traffic) but the
            // converter has no V7 branch, so it publishes nothing.
            let rejections_before = metrics.udp_template_rejections.load(Ordering::Relaxed);
            sender.send_to(&legacy(7), addr).await.unwrap();
            sleep(Duration::from_millis(300)).await;
            assert_eq!(
                metrics.udp_template_rejections.load(Ordering::Relaxed),
                rejections_before,
                "structurally valid v7 must not count as template traffic"
            );
            assert!(rx.try_recv().is_err());
            assert_eq!(
                metrics.udp_template_rejections.load(Ordering::Relaxed),
                if insecure { 0 } else { 3 }
            );
            task.abort();
            let _ = task.await;
            assert_eq!(metrics.source_count.load(Ordering::Relaxed), 0);
        }
    }

    #[tokio::test]
    async fn udp_secure_defaults_admit_jumbo_legacy_datagrams() {
        use crate::test_packets::{ipfix, legacy};
        // One PDU carrying exactly `count` records; callers must respect
        // the parser's per-PDU caps (v5: 30, v7: 28). A legitimate jumbo
        // datagram concatenates individually bounded PDUs.
        fn bounded_pdu(version: u16, count: u16) -> Vec<u8> {
            let base = legacy(version);
            let record = if version == 7 { 52 } else { 48 };
            let mut out = vec![0u8; 24 + record * usize::from(count)];
            out[..24].copy_from_slice(&base[..24]);
            out[2..4].copy_from_slice(&count.to_be_bytes());
            for i in 0..usize::from(count) {
                out[24 + i * record..24 + (i + 1) * record].copy_from_slice(&base[24..24 + record]);
            }
            out
        }
        let config: ListenerConfig = serde_json::from_value(serde_json::json!({
            "protocol": "netflow", "listen_addr": "127.0.0.1:0", "subject": "flows.raw.netflow",
            "allow_unauthenticated_templates": false
        }))
        .unwrap();
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        let metrics = Arc::new(ListenerMetrics::new("netflow", addr.to_string()));
        let (tx, mut rx) = mpsc::channel(64);
        let listener = Listener::new(
            build_handler(&config, Arc::clone(&metrics)),
            socket,
            65536,
            "flows.raw.netflow".into(),
            Arc::new(HostSliceRouter::default()),
            tx,
            Arc::clone(&metrics),
            Arc::new(SubjectDropRegistry::new()),
        );
        let task = tokio::spawn(listener.run());
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        // A bounded jumbo PDU publishes every record.
        sender.send_to(&bounded_pdu(5, 30), addr).await.unwrap();
        for _ in 0..30 {
            let (_, bytes, _) = timeout(Duration::from_secs(3), rx.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(FlowMessage::decode(bytes.as_slice()).unwrap().bytes, 111);
        }
        // A legitimate jumbo datagram concatenates bounded PDUs.
        let concat = [bounded_pdu(5, 30), bounded_pdu(5, 30)].concat();
        sender.send_to(&concat, addr).await.unwrap();
        for _ in 0..60 {
            let (_, bytes, _) = timeout(Duration::from_secs(3), rx.recv())
                .await
                .unwrap()
                .unwrap();
            assert_eq!(FlowMessage::decode(bytes.as_slice()).unwrap().bytes, 111);
        }
        assert_eq!(metrics.udp_template_rejections.load(Ordering::Relaxed), 0);
        // One PDU over the parser cap is denied even with exact byte
        // layout, as are zero counts and truncation.
        let mut zero_count = legacy(5);
        zero_count[2..4].copy_from_slice(&0u16.to_be_bytes());
        let truncated = bounded_pdu(5, 30)[..100].to_vec();
        let mut expected_rejections = 0u64;
        for bad in [
            bounded_pdu(5, 31),
            bounded_pdu(7, 29),
            zero_count,
            truncated,
        ] {
            sender.send_to(&bad, addr).await.unwrap();
            expected_rejections += 1;
            timeout(Duration::from_secs(3), async {
                while metrics.udp_template_rejections.load(Ordering::Relaxed) != expected_rejections
                {
                    sleep(Duration::from_millis(5)).await;
                }
            })
            .await
            .expect("over-cap or malformed legacy datagram was admitted");
            assert!(rx.try_recv().is_err());
        }
        let mut prefixed = [bounded_pdu(5, 30), bounded_pdu(5, 30)].concat();
        prefixed.extend_from_slice(&ipfix(1, Some(&[(1, 4)]), &999u32.to_be_bytes()));
        sender.send_to(&prefixed, addr).await.unwrap();
        expected_rejections += 1;
        timeout(Duration::from_secs(3), async {
            while metrics.udp_template_rejections.load(Ordering::Relaxed) != expected_rejections {
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("jumbo legacy prefix hid a trailing template packet");
        assert!(rx.try_recv().is_err());
        task.abort();
        let _ = task.await;
        assert_eq!(metrics.source_count.load(Ordering::Relaxed), 0);
    }

    struct StaticFlowHandler;

    impl FlowHandler for StaticFlowHandler {
        fn parse_datagram(&self, _buf: &[u8], _len: usize, _peer: SocketAddr) -> Vec<FlowMessage> {
            vec![FlowMessage {
                src_addr: vec![192, 0, 2, 10],
                dst_addr: vec![203, 0, 113, 5],
                bytes: 128,
                packets: 1,
                ..Default::default()
            }]
        }

        fn protocol_name(&self) -> &'static str {
            "test"
        }
    }

    #[tokio::test]
    async fn listener_publishes_matching_host_slice_subject() {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        let (tx, mut rx) = mpsc::channel(4);
        let metrics = Arc::new(ListenerMetrics::new("test", addr.to_string()));
        let router = Arc::new(HostSliceRouter::from_config(&config_with_slice()));
        let subject_drops = Arc::new(SubjectDropRegistry::new());

        let listener = Listener::new(
            Box::new(StaticFlowHandler),
            socket,
            1024,
            "flows.raw.test".to_string(),
            router,
            tx,
            metrics,
            subject_drops,
        );

        let handle = tokio::spawn(async move {
            let _ = listener.run().await;
        });

        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        sender.send_to(b"flow", addr).await.unwrap();

        let first = timeout(Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let second = timeout(Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();
        handle.abort();

        let mut subjects = vec![first.0.clone(), second.0.clone()];
        subjects.sort();

        assert_eq!(
            subjects,
            vec![
                "flow.host-slice.agent-1".to_string(),
                "flows.raw.test".to_string()
            ]
        );

        let host_slice_payload = if first.0 == "flow.host-slice.agent-1" {
            first.1.as_slice()
        } else {
            second.1.as_slice()
        };
        // Ingress timestamps must be present on both channel items.
        let _ = first.2;
        let _ = second.2;
        let decoded = AttributedFlowMessage::decode(host_slice_payload).expect("host slice decode");

        assert_eq!(decoded.event_type, "host_slice_flow");
        assert_eq!(decoded.agent_id, "agent-1");
        assert_eq!(decoded.partition, "default");
        assert!(decoded.flow.is_some());
    }

    #[tokio::test]
    async fn listener_records_per_subject_drops_when_channel_full() {
        // Capacity 1 + we never drain the receiver, so the first publish_encoded
        // succeeds (raw subject) and every subsequent send to either the raw
        // subject or a host-slice subject hits TrySendError::Full.
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        let (tx, _rx) = mpsc::channel(1);
        let metrics = Arc::new(ListenerMetrics::new("test", addr.to_string()));
        let router = Arc::new(HostSliceRouter::from_config(&config_with_slice()));
        let subject_drops = Arc::new(SubjectDropRegistry::new());

        let listener = Listener::new(
            Box::new(StaticFlowHandler),
            socket,
            1024,
            "flows.raw.test".to_string(),
            router,
            tx,
            Arc::clone(&metrics),
            Arc::clone(&subject_drops),
        );

        let handle = tokio::spawn(async move {
            let _ = listener.run().await;
        });

        // Drive enough datagrams through that we exhaust the channel and
        // observe at least one drop on each subject.
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        for _ in 0..16 {
            sender.send_to(b"flow", addr).await.unwrap();
        }

        // Give the listener time to process.
        sleep(Duration::from_millis(200)).await;
        handle.abort();

        let snapshot = subject_drops.snapshot();
        let by_subject: std::collections::HashMap<String, u64> = snapshot.into_iter().collect();

        // The raw subject *might* also drop (after the first success the
        // channel is full), but we definitely expect the host-slice fan-out
        // to drop on every datagram beyond the first, because the raw send
        // always consumes the single slot first.
        assert!(
            by_subject
                .get("flow.host-slice.agent-1")
                .copied()
                .unwrap_or(0)
                > 0,
            "expected host-slice subject drops, got {:?}",
            by_subject
        );

        let channel_full = metrics.channel_full_drops.load(Ordering::Relaxed);
        assert!(
            channel_full > 0,
            "expected channel_full_drops to be incremented"
        );

        // Degenerate-flow counter must not be touched by channel-full drops.
        assert_eq!(metrics.flows_dropped.load(Ordering::Relaxed), 0);
    }

    fn config_with_slice() -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            nats_creds_file: None,
            stream_name: "flows".to_string(),
            stream_subjects: None,
            stream_max_bytes: 1024,
            stream_max_age_secs: 3600,
            stream_replicas: 1,
            rehome_state_path: None,
            template_store: None,
            ready_state_path: None,
            partition: "default".to_string(),
            channel_size: 100,
            batch_size: 10,
            publish_timeout_ms: 1000,
            security: None,
            metrics_addr: None,
            host_slice_allowlist: vec!["agent-1".to_string()],
            host_slices: vec![HostSliceConfig {
                agent_id: "agent-1".to_string(),
                partition: "default".to_string(),
                host_ips: vec![IpAddr::V4(Ipv4Addr::new(192, 0, 2, 10))],
                host_network_visibility: HostNetworkVisibilityStatus::Enabled,
            }],
            listeners: vec![ListenerConfig::Sflow {
                listen_addr: "127.0.0.1:6343".to_string(),
                subject: "flows.raw.sflow".to_string(),
                buffer_size: 1024,
                channel_size: None,
                max_samples_per_datagram: None,
            }],
        }
    }
}
