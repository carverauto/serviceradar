pub mod converter;

use crate::error::GetCurrentTimeError;
use crate::listener::FlowHandler;
use crate::metrics::ListenerMetrics;
use converter::flowpb::FlowMessage;
use converter::{Converter, is_valid_flow};
use flowparser_sflow::SflowParser;
use log::{debug, warn};
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};

pub struct SflowHandler {
    parser: SflowParser,
    metrics: Arc<ListenerMetrics>,
}

impl SflowHandler {
    pub fn new(max_samples_per_datagram: Option<u32>, metrics: Arc<ListenerMetrics>) -> Self {
        let parser = if let Some(max_samples) = max_samples_per_datagram {
            SflowParser::builder()
                .with_max_samples(max_samples)
                .build()
        } else {
            SflowParser::default()
        };

        Self { parser, metrics }
    }

    fn get_current_time_ns() -> Result<u64, GetCurrentTimeError> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(GetCurrentTimeError::SystemTimeError)?;
        u64::try_from(duration.as_nanos()).map_err(GetCurrentTimeError::TryFromIntError)
    }
}

impl FlowHandler for SflowHandler {
    fn parse_datagram(&self, buf: &[u8], _len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
        let receive_time_ns = match Self::get_current_time_ns() {
            Ok(t) => t,
            Err(e) => {
                warn!("Failed to get current time: {}", e);
                return vec![];
            }
        };

        debug!("Received {} bytes from {}", buf.len(), peer);

        let result = self.parser.parse_bytes(buf);

        if let Some(ref err) = result.error {
            warn!("sFlow parse error from {}: {:?}", peer, err);
            self.metrics.parse_errors.fetch_add(1, Ordering::Relaxed);
        }

        let mut all_messages = Vec::new();

        for datagram in result.datagrams {
            debug!(
                "Parsed sFlow datagram from {}: seq={}, samples={}",
                peer, datagram.sequence_number, datagram.samples.len()
            );

            let converter = Converter::new(datagram, peer, receive_time_ns);
            let flow_messages = converter.convert();

            let (valid, invalid): (Vec<_>, Vec<_>) =
                flow_messages.into_iter().partition(is_valid_flow);

            if !invalid.is_empty() {
                warn!(
                    "Dropped {} degenerate flow record(s) from {} (0 bytes, 0 packets)",
                    invalid.len(),
                    peer
                );
                self.metrics
                    .flows_dropped
                    .fetch_add(invalid.len() as u64, Ordering::Relaxed);
            }

            self.metrics
                .flows_converted
                .fetch_add(valid.len() as u64, Ordering::Relaxed);

            all_messages.extend(valid);
        }

        all_messages
    }

    fn protocol_name(&self) -> &'static str {
        "sflow"
    }
}
