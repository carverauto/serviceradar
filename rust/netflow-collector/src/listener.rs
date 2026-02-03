use crate::config::Config;
use crate::converter::{Converter, is_valid_flow};
use crate::converter::flowpb;
use crate::error::GetCurrentTimeError;
use crate::pending_buffer::PendingPacketBuffer;
use anyhow::Result;
use log::{debug, error, info, warn};
use netflow_parser::{AutoScopedParser, NetflowPacket, NetflowParserBuilder, TemplateEvent};
use prost::Message;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
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
    pending_buffer: Mutex<PendingPacketBuffer>,
    templates_learned: Arc<AtomicBool>,
}

impl Listener {
    pub async fn new(config: Arc<Config>, tx: mpsc::Sender<Vec<u8>>) -> Result<Self> {
        let socket = UdpSocket::bind(&config.listen_addr).await?;
        info!("NetFlow collector listening on {}", config.listen_addr);

        let templates_learned = Arc::new(AtomicBool::new(false));
        let tl_clone = templates_learned.clone();

        let builder = NetflowParserBuilder::default()
            .with_cache_size(config.max_templates)
            .on_template_event(move |event: &TemplateEvent| {
                template_event_callback(event);
                if matches!(event, TemplateEvent::Learned { .. }) {
                    tl_clone.store(true, Ordering::Relaxed);
                }
            });

        let parser = AutoScopedParser::with_builder(builder);

        let pending_buffer = PendingPacketBuffer::new(
            Duration::from_secs(config.pending_packet_ttl_secs),
            config.max_pending_packets,
        );

        Ok(Self {
            config,
            socket: Arc::new(socket),
            parser: Mutex::new(parser),
            tx,
            pending_buffer: Mutex::new(pending_buffer),
            templates_learned,
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

    /// Process a single parsed NetFlow packet: convert, filter, encode, and send.
    /// Returns (valid_count, dropped_count).
    fn process_parsed_packet(
        &self,
        packet: NetflowPacket,
        peer_addr: SocketAddr,
        receive_time_ns: u64,
    ) -> Result<(usize, usize)> {
        debug!("Parsed NetFlow packet {:?}", packet);

        let flow_messages: Vec<flowpb::FlowMessage> =
            match Converter::new(packet, peer_addr, receive_time_ns).try_into() {
                Ok(messages) => messages,
                Err(e) => {
                    warn!("Failed to convert NetFlow packet to protobuf: {:?}", e);
                    return Ok((0, 0));
                }
            };

        // Filter out degenerate flow records (0 bytes, 0 packets)
        let (valid, invalid): (Vec<_>, Vec<_>) =
            flow_messages.into_iter().partition(is_valid_flow);

        if !invalid.is_empty() {
            warn!(
                "Dropped {} degenerate flow record(s) from {} \
                 (0 bytes, 0 packets - likely options template or metadata)",
                invalid.len(),
                peer_addr
            );
            for dropped in &invalid {
                debug!(
                    "Dropped flow: proto={} protocol_name={:?} src_addr={:?} dst_addr={:?} \
                     src_port={} dst_port={} type={:?}",
                    dropped.proto,
                    dropped.protocol_name,
                    dropped.src_addr,
                    dropped.dst_addr,
                    dropped.src_port,
                    dropped.dst_port,
                    dropped.r#type,
                );
            }
        }

        let valid_count = valid.len();
        let dropped_count = invalid.len();
        debug!("Converted {} flow records ({} dropped)", valid_count, dropped_count);

        // Encode and send each valid flow message to the publisher channel
        for flow_msg in valid {
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
                }
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    error!("Publisher channel closed, stopping listener");
                    return Err(anyhow::anyhow!("Publisher channel closed"));
                }
            }
        }

        Ok((valid_count, dropped_count))
    }

    async fn process_packet(&self, data: &[u8], peer_addr: SocketAddr) -> Result<()> {
        let receive_time_ns = Self::get_current_time_ns()?;

        debug!("Received {} bytes from {}", data.len(), peer_addr);

        // Parse NetFlow packets - iter_packets_from_source returns an iterator of Results
        let packets: Vec<_> = {
            let mut parser = self.parser.lock().unwrap();
            parser.iter_packets_from_source(peer_addr, data).collect()
        };

        // Check if templates were learned during this parse (swap to false)
        let templates_were_learned = self.templates_learned.swap(false, Ordering::Relaxed);

        let mut had_errors = false;
        for packet_result in packets {
            match packet_result {
                Ok(packet) => {
                    self.process_parsed_packet(packet, peer_addr, receive_time_ns)?;
                }
                Err(e) => {
                    warn!("Failed to parse NetFlow packet from {}: {:?}", peer_addr, e);
                    had_errors = true;
                }
            }
        }

        // If there were parse errors, buffer the raw packet for later retry
        if had_errors {
            let mut pending = self.pending_buffer.lock().unwrap();
            pending.add(peer_addr, data.to_vec(), receive_time_ns);
            info!(
                "Buffered pending packet from {} ({} bytes)",
                peer_addr,
                data.len()
            );
        }

        // If new templates were learned, retry any pending packets for this source
        if templates_were_learned && self.pending_buffer.lock().unwrap().has_pending(&peer_addr) {
            self.retry_pending_packets(peer_addr)?;
        }

        Ok(())
    }

    fn retry_pending_packets(&self, peer_addr: SocketAddr) -> Result<()> {
        let pending_packets = self.pending_buffer.lock().unwrap().take_all(&peer_addr);
        let count = pending_packets.len();
        if count == 0 {
            return Ok(());
        }

        info!("Retrying {} pending packet(s) for {}", count, peer_addr);

        let mut recovered = 0usize;
        let mut still_pending = 0usize;

        for pkt in pending_packets {
            // Check if this packet has expired
            if self.pending_buffer.lock().unwrap().is_expired(&pkt) {
                debug!(
                    "Dropping expired pending packet from {} ({} bytes)",
                    peer_addr,
                    pkt.data.len()
                );
                continue;
            }

            // Re-parse with current template state
            let packets: Vec<_> = {
                let mut parser = self.parser.lock().unwrap();
                parser
                    .iter_packets_from_source(peer_addr, &pkt.data)
                    .collect()
            };

            let mut had_errors = false;
            for packet_result in packets {
                match packet_result {
                    Ok(packet) => {
                        self.process_parsed_packet(packet, peer_addr, pkt.receive_time_ns)?;
                        recovered += 1;
                    }
                    Err(e) => {
                        debug!(
                            "Still failing to parse pending packet from {}: {:?}",
                            peer_addr, e
                        );
                        had_errors = true;
                    }
                }
            }

            // If still has errors, re-buffer
            if had_errors {
                self.pending_buffer.lock().unwrap().re_add(peer_addr, pkt);
                still_pending += 1;
            }
        }

        info!(
            "Pending retry for {}: {} recovered, {} still pending",
            peer_addr, recovered, still_pending
        );

        Ok(())
    }

    pub fn sweep_pending_buffer(&self) {
        self.pending_buffer.lock().unwrap().sweep_expired();
    }

    pub fn get_pending_stats(&self) -> (usize, usize) {
        self.pending_buffer.lock().unwrap().stats()
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
