use crate::config::Config;
use crate::converter::Converter;
use crate::converter::flowpb;
use crate::error::GetCurrentTimeError;
use anyhow::Result;
use log::{debug, error, info, warn};
use netflow_parser::{AutoScopedParser, NetflowParserBuilder, TemplateEvent};
use prost::Message;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

type CacheStatsVec = Vec<(String, netflow_parser::ParserCacheStats)>;

fn template_event_callback(event: &TemplateEvent) {
    use TemplateEvent::*;
    match event {
        Learned {
            template_id,
            protocol,
        } => {
            info!(
                "Template learned - ID: {}, Protocol: {:?}",
                template_id, protocol
            );
        }
        Collision {
            template_id,
            protocol,
        } => {
            warn!(
                "Template collision - ID: {}, Protocol: {:?}",
                template_id, protocol
            );
        }
        Evicted {
            template_id,
            protocol,
        } => {
            debug!(
                "Template evicted - ID: {}, Protocol: {:?}",
                template_id, protocol
            );
        }
        Expired {
            template_id,
            protocol,
        } => {
            debug!(
                "Template expired - ID: {}, Protocol: {:?}",
                template_id, protocol
            );
        }
        MissingTemplate {
            template_id,
            protocol,
        } => {
            warn!(
                "Missing template - ID: {}, Protocol: {:?}. \
                   Flow data received before template definition.",
                template_id, protocol
            );
        }
    }
}

pub struct Listener {
    config: Arc<Config>,
    socket: Arc<UdpSocket>,
    parser: Mutex<AutoScopedParser>,
    tx: mpsc::Sender<Vec<u8>>,
}

impl Listener {
    pub async fn new(config: Arc<Config>, tx: mpsc::Sender<Vec<u8>>) -> Result<Self> {
        let socket = UdpSocket::bind(&config.listen_addr).await?;
        info!("NetFlow collector listening on {}", config.listen_addr);

        let builder = NetflowParserBuilder::default()
            .with_cache_size(config.max_templates)
            .on_template_event(template_event_callback);

        let parser = AutoScopedParser::with_builder(builder);

        Ok(Self {
            config,
            socket: Arc::new(socket),
            parser: Mutex::new(parser),
            tx,
        })
    }

    pub async fn run(self: Arc<Self>) -> Result<()> {
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

    fn get_current_time_ns() -> Result<u64, GetCurrentTimeError> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(GetCurrentTimeError::SystemTimeError)?;
        u64::try_from(duration.as_nanos()).map_err(GetCurrentTimeError::TryFromIntError)
    }

    async fn process_packet(&self, data: &[u8], peer_addr: SocketAddr) -> Result<()> {
        let receive_time_ns = Self::get_current_time_ns()?;

        debug!("Received {} bytes from {}", data.len(), peer_addr);

        // Parse NetFlow packets - iter_packets_from_source returns an iterator of Results
        let packets: Vec<_> = {
            let mut parser = self.parser.lock().unwrap();
            parser.iter_packets_from_source(peer_addr, data).collect()
        };

        for packet_result in packets {
            let packet = match packet_result {
                Ok(p) => p,
                Err(e) => {
                    warn!("Failed to parse NetFlow packet from {}: {:?}", peer_addr, e);
                    continue;
                }
            };
            debug!("Parsed NetFlow packet {:?}", packet);

            let flow_messages: Vec<flowpb::FlowMessage> =
                match Converter::new(packet, peer_addr, receive_time_ns).try_into() {
                    Ok(messages) => messages,
                    Err(e) => {
                        warn!("Failed to convert NetFlow packet to protobuf: {:?}", e);
                        continue; // Skip this packet and continue with the next
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
        }

        Ok(())
    }

    pub fn get_cache_stats(&self) -> (CacheStatsVec, CacheStatsVec) {
        let parser = self.parser.lock().unwrap();
        let v9_stats: Vec<_> = parser
            .v9_stats()
            .iter()
            .map(|(key, stats)| (format!("{:?}", key), stats.clone()))
            .collect();
        let ipfix_stats: Vec<_> = parser
            .ipfix_stats()
            .iter()
            .map(|(key, stats)| (format!("{:?}", key), stats.clone()))
            .collect();
        (v9_stats, ipfix_stats)
    }
}
