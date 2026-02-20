use crate::config::ListenerConfig;
use crate::metrics::ListenerMetrics;
use crate::netflow::NetflowHandler;
use crate::sflow::SflowHandler;
use crate::sflow::converter::flowpb::FlowMessage;
use anyhow::Result;
use log::{error, info, warn};
use prost::Message;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

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
                        let mut encoded = Vec::new();
                        if let Err(e) = flow_msg.encode(&mut encoded) {
                            error!("[{}] Failed to encode protobuf: {}", protocol, e);
                            continue;
                        }

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
