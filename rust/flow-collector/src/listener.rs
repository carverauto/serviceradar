use crate::config::ListenerConfig;
use crate::error::GetCurrentTimeError;
use crate::flowpb::FlowMessage;
use crate::metrics::ListenerMetrics;
use crate::netflow::NetflowHandler;
use crate::sflow::SflowHandler;
use anyhow::Result;
use log::{error, info, warn};
use prost::Message;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
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
    tx: mpsc::Sender<(String, Vec<u8>)>,
    subject: String,
    metrics: Arc<ListenerMetrics>,
}

impl Listener {
    pub fn new(
        handler: Box<dyn FlowHandler>,
        socket: UdpSocket,
        buffer_size: usize,
        subject: String,
        tx: mpsc::Sender<(String, Vec<u8>)>,
        metrics: Arc<ListenerMetrics>,
    ) -> Self {
        Self {
            handler,
            socket,
            buffer_size,
            tx,
            subject,
            metrics,
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

                        match self.tx.try_send((self.subject.clone(), encoded)) {
                            Ok(_) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                warn!(
                                    "[{}] Publisher channel full, dropping flow message",
                                    protocol
                                );
                                self.metrics.flows_dropped.fetch_add(1, Ordering::Relaxed);
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                error!(
                                    "[{}] Publisher channel closed, stopping listener",
                                    protocol
                                );
                                return Err(anyhow::anyhow!("Publisher channel closed"));
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
        ListenerConfig::Netflow {
            max_templates,
            pending_flows,
            ..
        } => Box::new(NetflowHandler::new(
            *max_templates,
            pending_flows.as_ref(),
            metrics,
        )),
    }
}
