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
    /// Per-listener bounded mpsc to the publisher fan-in. Each listener owns
    /// its own sender so a noisy protocol cannot starve a quiet one when the
    /// shared NATS publisher batches behind. The downstream consumer pattern
    /// is `DropNewest` (tokio `mpsc::try_send` rejects the incoming message
    /// when the channel is full); see `config.rs` for why we do not expose
    /// a `DropOldest` policy.
    tx: mpsc::Sender<OutboundFlow>,
    subject: String,
    host_slice_router: Arc<HostSliceRouter>,
    metrics: Arc<ListenerMetrics>,
    /// Records per-NATS-subject channel-full drops so operators can see
    /// *which* listener and *which* subject is overflowing — not just an
    /// aggregate counter.
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
            tx,
            subject,
            host_slice_router,
            metrics,
            subject_drops,
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
                    self.metrics
                        .packets_received
                        .fetch_add(1, Ordering::Relaxed);
                    let messages = self.handler.parse_datagram(&buf[..len], len, peer_addr);

                    for flow_msg in messages {
                        let encoded = flow_to_bytes(&flow_msg);

                        if !self
                            .publish_encoded(protocol, self.subject.clone(), encoded.clone())
                            .await?
                        {
                            continue;
                        }

                        for target in self.host_slice_router.targets_for_flow(&flow_msg) {
                            let host_slice_encoded = host_slice_flow_to_bytes(
                                &flow_msg,
                                target.agent_id.as_ref(),
                                target.partition.as_ref(),
                            );
                            if !self
                                .publish_encoded(
                                    protocol,
                                    target.subject.to_string(),
                                    host_slice_encoded,
                                )
                                .await?
                            {
                                break;
                            }
                        }
                    }
                }
                Err(e) => {
                    error!("[{}] Error receiving UDP packet: {}", protocol, e);
                }
            }
        }
    }

    async fn publish_encoded(
        &self,
        protocol: &str,
        subject: String,
        encoded: Vec<u8>,
    ) -> Result<bool> {
        // Stamp ingress at UDP accept so publisher never-attempted TTL bounds
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
///
/// `template_store` is supplied by `main` when a NATS KV bucket is
/// configured and is shared across all NetFlow listeners. sFlow ignores it
/// because sFlow is template-less.
pub fn build_handler(
    config: &ListenerConfig,
    template_store: Option<Arc<dyn netflow_parser::TemplateStore>>,
    metrics: Arc<ListenerMetrics>,
) -> Box<dyn FlowHandler> {
    match config {
        ListenerConfig::Sflow {
            max_samples_per_datagram,
            ..
        } => Box::new(SflowHandler::new(*max_samples_per_datagram, metrics)),
        ListenerConfig::Netflow {
            max_templates,
            pending_flows,
            default_sampling_rate,
            sampling_rate_overrides,
            max_sources,
            ..
        } => Box::new(NetflowHandler::new(
            *max_templates,
            pending_flows.as_ref(),
            *default_sampling_rate,
            sampling_rate_overrides.clone(),
            *max_sources,
            template_store,
            metrics,
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, HostNetworkVisibilityStatus, HostSliceConfig, ListenerConfig};
    use std::net::{IpAddr, Ipv4Addr};
    use tokio::time::{Duration, sleep, timeout};

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
