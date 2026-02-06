use crate::config::Config;
use crate::converter::{mdnspb, parse_mdns_packet};
use crate::dedup::DedupCache;
use crate::error::GetCurrentTimeError;
use anyhow::Result;
use log::{debug, error, info, warn};
use prost::Message;
use socket2::{Domain, Protocol, Socket, Type};
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

pub struct Listener {
    config: Arc<Config>,
    socket: Arc<UdpSocket>,
    dedup: Arc<DedupCache>,
    tx: mpsc::Sender<Vec<u8>>,
}

impl Listener {
    pub async fn new(
        config: Arc<Config>,
        dedup: Arc<DedupCache>,
        tx: mpsc::Sender<Vec<u8>>,
    ) -> Result<Self> {
        let socket = setup_multicast_socket(&config)?;
        let tokio_socket = UdpSocket::from_std(socket.into())?;

        info!(
            "mDNS collector listening on {}, multicast groups: {:?}",
            config.listen_addr, config.multicast_groups
        );

        Ok(Self {
            config,
            socket: Arc::new(tokio_socket),
            dedup,
            tx,
        })
    }

    pub async fn run(self: Arc<Self>) -> Result<()> {
        let mut buf = vec![0u8; self.config.buffer_size];

        loop {
            match self.socket.recv_from(&mut buf).await {
                Ok((len, peer_addr)) => {
                    if let Err(e) = self.process_packet(&buf[..len], peer_addr).await {
                        error!("Error processing mDNS packet from {}: {}", peer_addr, e);
                    }
                }
                Err(e) => {
                    error!("Error receiving mDNS UDP packet: {}", e);
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

        let records = parse_mdns_packet(data, peer_addr.ip(), receive_time_ns);

        if records.is_empty() {
            return Ok(());
        }

        debug!("Parsed {} mDNS records from {}", records.len(), peer_addr);

        for record in records {
            // Apply dedup
            if !self
                .dedup
                .check_and_insert(&record.hostname, &record.resolved_addr)
            {
                debug!(
                    "Dedup: suppressing duplicate record for {}",
                    record.hostname
                );
                continue;
            }

            self.send_record(record)?;
        }

        Ok(())
    }

    fn send_record(&self, record: mdnspb::MdnsRecord) -> Result<()> {
        let mut buf = Vec::new();
        if let Err(e) = record.encode(&mut buf) {
            error!("Failed to encode mDNS protobuf: {}", e);
            return Ok(());
        }

        match self.tx.try_send(buf) {
            Ok(_) => {}
            Err(mpsc::error::TrySendError::Full(_)) => {
                warn!("Publisher channel full, dropping mDNS record");
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                error!("Publisher channel closed, stopping mDNS listener");
                return Err(anyhow::anyhow!("Publisher channel closed"));
            }
        }

        Ok(())
    }
}

fn setup_multicast_socket(config: &Config) -> Result<std::net::UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;

    socket.set_reuse_address(true)?;
    // SO_REUSEPORT is available on Unix-like systems
    #[cfg(unix)]
    socket.set_reuse_port(true)?;

    socket.set_nonblocking(true)?;

    let addr: SocketAddr = config.listen_addr.parse()?;
    socket.bind(&addr.into())?;

    // Join multicast groups
    for group in &config.multicast_groups {
        let multicast_addr: Ipv4Addr = group.parse()?;
        let interface = if let Some(iface) = &config.listen_interface {
            iface.parse()?
        } else {
            Ipv4Addr::UNSPECIFIED
        };

        socket.join_multicast_v4(&multicast_addr, &interface)?;
        info!("Joined multicast group {} on interface {}", group, interface);
    }

    Ok(socket.into())
}
