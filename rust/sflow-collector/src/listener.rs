use crate::config::Config;
use crate::converter::{Converter, is_valid_flow};
use crate::error::GetCurrentTimeError;
use anyhow::Result;
use flowparser_sflow::SflowParser;
use log::{debug, error, info, warn};
use prost::Message;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

pub struct Listener {
    config: Arc<Config>,
    socket: UdpSocket,
    parser: SflowParser,
    tx: mpsc::Sender<Vec<u8>>,
    pub packets_received: AtomicU64,
    pub flows_converted: AtomicU64,
    pub flows_dropped: AtomicU64,
    pub parse_errors: AtomicU64,
}

impl Listener {
    pub fn new(config: Arc<Config>, tx: mpsc::Sender<Vec<u8>>) -> Result<Self> {
        let std_socket = std::net::UdpSocket::bind(&config.listen_addr)?;
        std_socket.set_nonblocking(true)?;
        let socket = UdpSocket::from_std(std_socket)?;
        info!("sFlow collector listening on {}", config.listen_addr);

        let parser = if let Some(max_samples) = config.max_samples_per_datagram {
            SflowParser::builder()
                .with_max_samples(max_samples)
                .build()
        } else {
            SflowParser::default()
        };

        Ok(Self {
            config,
            socket,
            parser,
            tx,
            packets_received: AtomicU64::new(0),
            flows_converted: AtomicU64::new(0),
            flows_dropped: AtomicU64::new(0),
            parse_errors: AtomicU64::new(0),
        })
    }

    pub async fn run(self: Arc<Self>) -> Result<()> {
        let mut buf = vec![0u8; self.config.buffer_size];

        loop {
            match self.socket.recv_from(&mut buf).await {
                Ok((len, peer_addr)) => {
                    self.packets_received.fetch_add(1, Ordering::Relaxed);
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

        let result = self.parser.parse_bytes(data);

        if let Some(ref err) = result.error {
            warn!("sFlow parse error from {}: {:?}", peer_addr, err);
            self.parse_errors.fetch_add(1, Ordering::Relaxed);
        }

        for datagram in result.datagrams {
            debug!(
                "Parsed sFlow datagram from {}: seq={}, samples={}",
                peer_addr,
                datagram.sequence_number,
                datagram.samples.len()
            );

            let converter = Converter::new(datagram, peer_addr, receive_time_ns);
            let flow_messages = converter.convert();

            // Filter out degenerate flow records (0 bytes, 0 packets)
            let (valid, invalid): (Vec<_>, Vec<_>) =
                flow_messages.into_iter().partition(is_valid_flow);

            if !invalid.is_empty() {
                warn!(
                    "Dropped {} degenerate flow record(s) from {} \
                     (0 bytes, 0 packets)",
                    invalid.len(),
                    peer_addr
                );
                self.flows_dropped
                    .fetch_add(invalid.len() as u64, Ordering::Relaxed);
            }

            debug!(
                "Converted {} flow records ({} dropped)",
                valid.len(),
                invalid.len()
            );

            self.flows_converted
                .fetch_add(valid.len() as u64, Ordering::Relaxed);

            // Encode and send each valid flow message to the publisher channel
            for flow_msg in valid {
                let mut buf = Vec::new();
                if let Err(e) = flow_msg.encode(&mut buf) {
                    error!("Failed to encode protobuf: {}", e);
                    continue;
                }

                match self.tx.try_send(buf) {
                    Ok(_) => {}
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        warn!("Publisher channel full, dropping flow message");
                        self.flows_dropped.fetch_add(1, Ordering::Relaxed);
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
}
