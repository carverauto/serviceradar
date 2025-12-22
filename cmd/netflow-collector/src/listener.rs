use crate::config::Config;
use crate::converter::{flowpb, get_current_time_ns, netflow_to_proto};
use anyhow::Result;
use log::{debug, error, info, warn};
use netflow_parser::{NetflowParser, NetflowPacket};
use prost::Message;
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

pub struct Listener {
    config: Arc<Config>,
    socket: Arc<UdpSocket>,
    parser: NetflowParser,
    tx: mpsc::Sender<Vec<u8>>,
}

impl Listener {
    pub async fn new(
        config: Arc<Config>,
        tx: mpsc::Sender<Vec<u8>>,
    ) -> Result<Self> {
        let socket = UdpSocket::bind(&config.listen_addr).await?;
        info!("NetFlow collector listening on {}", config.listen_addr);

        // Initialize parser with template TTL support (netflow_parser 0.6.9 feature)
        let parser = NetflowParser::default();

        Ok(Self {
            config,
            socket: Arc::new(socket),
            parser,
            tx,
        })
    }

    pub async fn run(mut self) -> Result<()> {
        let mut buf = vec![0u8; self.config.buffer_size];

        loop {
            match self.socket.recv_from(&mut buf).await {
                Ok((len, peer_addr)) => {
                    if let Err(e) = self.process_packet(&buf[..len], peer_addr).await {
                        error!("Error processing packet from {}: {}", peer_addr, e);
                    }
                }
                Err(e) => {
                    error!("Error receiving UDP packet: {}", e);
                }
            }
        }
    }

    async fn process_packet(&mut self, data: &[u8], peer_addr: SocketAddr) -> Result<()> {
        let receive_time_ns = get_current_time_ns();

        debug!(
            "Received {} bytes from {}",
            data.len(),
            peer_addr
        );

        // Parse NetFlow packet
        let packet = match self.parser.parse_bytes(data) {
            Ok(packet) => packet,
            Err(e) => {
                warn!("Failed to parse NetFlow packet from {}: {}", peer_addr, e);
                return Ok(()); // Don't fail the loop, just skip this packet
            }
        };

        debug!(
            "Parsed NetFlow packet type: {:?}",
            netflow_type_name(&packet)
        );

        // Convert to protobuf messages
        let flow_messages = match netflow_to_proto(packet, peer_addr, receive_time_ns) {
            Ok(messages) => messages,
            Err(e) => {
                warn!("Failed to convert NetFlow packet to protobuf: {}", e);
                return Ok(());
            }
        };

        debug!("Converted {} flow records", flow_messages.len());

        // Encode and send each flow message to the publisher channel
        for flow_msg in flow_messages {
            let mut buf = Vec::new();
            if let Err(e) = flow_msg.encode(&mut buf) {
                error!("Failed to encode protobuf: {}", e);
                continue;
            }

            // Send to publisher channel (non-blocking with backpressure handling)
            match self.tx.try_send(buf) {
                Ok(_) => {}
                Err(mpsc::error::TrySendError::Full(_)) => {
                    warn!("Publisher channel full, dropping flow message");
                    // TODO: Increment metrics counter for drops
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    error!("Publisher channel closed, stopping listener");
                    return Err(anyhow::anyhow!("Publisher channel closed"));
                }
            }
        }

        Ok(())
    }
}

fn netflow_type_name(packet: &NetflowPacket) -> &'static str {
    match packet {
        NetflowPacket::V5(_) => "NetFlow v5",
        NetflowPacket::V7(_) => "NetFlow v7",
        NetflowPacket::V9(_) => "NetFlow v9",
        NetflowPacket::IPFix(_) => "IPFIX",
        _ => "Unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_netflow_type_name() {
        // This test would require creating sample NetFlow packets
        // For now, it's a placeholder
    }
}
