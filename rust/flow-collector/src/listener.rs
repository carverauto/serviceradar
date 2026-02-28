use crate::config::ListenerConfig;
use crate::error::GetCurrentTimeError;
use crate::metrics::ListenerMetrics;
use crate::netflow::NetflowHandler;
use crate::sflow::SflowHandler;
use crate::flowpb::FlowMessage;
use anyhow::Result;
use log::{error, info, warn};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
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

/// Convert raw IP bytes to a string representation.
fn bytes_to_ip(bytes: &[u8]) -> Option<String> {
    match bytes.len() {
        4 => {
            let addr = Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]);
            Some(IpAddr::V4(addr).to_string())
        }
        16 => {
            let octets: [u8; 16] = bytes.try_into().ok()?;
            let addr = Ipv6Addr::from(octets);
            Some(IpAddr::V6(addr).to_string())
        }
        _ => None,
    }
}

fn mac_to_string(mac: u64) -> Option<String> {
    if mac == 0 {
        return None;
    }

    Some(format!(
        "{:02X}:{:02X}:{:02X}:{:02X}:{:02X}:{:02X}",
        (mac >> 40) & 0xFF,
        (mac >> 32) & 0xFF,
        (mac >> 24) & 0xFF,
        (mac >> 16) & 0xFF,
        (mac >> 8) & 0xFF,
        mac & 0xFF
    ))
}

/// Map FlowType enum to a human-readable version label.
fn flow_source_label(flow_type: i32) -> &'static str {
    use crate::flowpb::flow_message::FlowType;
    match FlowType::try_from(flow_type) {
        Ok(FlowType::Sflow5) => "sFlow v5",
        Ok(FlowType::NetflowV5) => "NetFlow v5",
        Ok(FlowType::NetflowV9) => "NetFlow v9",
        Ok(FlowType::Ipfix) => "IPFIX",
        _ => "Unknown",
    }
}

/// Serialize a FlowMessage to JSON bytes for the Elixir EventWriter.
pub fn flow_to_json(msg: &FlowMessage) -> Option<Vec<u8>> {
    let src_addr = bytes_to_ip(&msg.src_addr).unwrap_or_default();
    let dst_addr = bytes_to_ip(&msg.dst_addr).unwrap_or_default();
    let sampler_addr = bytes_to_ip(&msg.sampler_address).unwrap_or_default();
    let src_mac = mac_to_string(msg.src_mac);
    let dst_mac = mac_to_string(msg.dst_mac);

    let json = serde_json::json!({
        "src_addr": src_addr,
        "dst_addr": dst_addr,
        "src_port": msg.src_port,
        "dst_port": msg.dst_port,
        "protocol": msg.proto,
        "packets": msg.packets,
        "bytes": msg.bytes,
        "bytes_in": msg.bytes_in,
        "bytes_out": msg.bytes_out,
        "packets_in": msg.packets_in,
        "packets_out": msg.packets_out,
        "sampling_rate": msg.sampling_rate,
        "sampler_address": sampler_addr,
        "input_snmp": msg.in_if,
        "output_snmp": msg.out_if,
        "tcp_flags": msg.tcp_flags,
        "ip_tos": msg.ip_tos,
        "src_as": msg.src_as,
        "dst_as": msg.dst_as,
        "protocol_name": msg.protocol_name,
        "src_mac": src_mac,
        "dst_mac": dst_mac,
        "timestamp": msg.time_received_ns,
        "flow_source": flow_source_label(msg.r#type),
    });

    serde_json::to_vec(&json).ok()
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
                    self.metrics.packets_received.fetch_add(1, Ordering::Relaxed);
                    let messages = self.handler.parse_datagram(&buf[..len], len, peer_addr);

                    for flow_msg in messages {
                        let encoded = match flow_to_json(&flow_msg) {
                            Some(json) => json,
                            None => {
                                error!("[{}] Failed to encode JSON", protocol);
                                continue;
                            }
                        };

                        match self.tx.try_send((self.subject.clone(), encoded)) {
                            Ok(_) => {}
                            Err(mpsc::error::TrySendError::Full(_)) => {
                                warn!("[{}] Publisher channel full, dropping flow message", protocol);
                                self.metrics.flows_dropped.fetch_add(1, Ordering::Relaxed);
                            }
                            Err(mpsc::error::TrySendError::Closed(_)) => {
                                error!("[{}] Publisher channel closed, stopping listener", protocol);
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
