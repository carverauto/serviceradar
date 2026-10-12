pub mod converter;

use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use crate::netflow::converter::DEFAULT_MAX_SAMPLING_RATE;
use converter::Converter;
use flowparser_sflow::SflowParser;
use log::{debug, warn};
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;

pub struct SflowHandler {
    parser: SflowParser,
    metrics: Arc<ListenerMetrics>,
    max_sampling_rate: u64,
}

impl SflowHandler {
    pub fn new(
        max_samples_per_datagram: Option<u32>,
        metrics: Arc<ListenerMetrics>,
        max_sampling_rate: Option<u64>,
    ) -> Self {
        let parser = if let Some(max_samples) = max_samples_per_datagram {
            SflowParser::builder().with_max_samples(max_samples).build()
        } else {
            SflowParser::default()
        };

        Self {
            parser,
            metrics,
            max_sampling_rate: max_sampling_rate
                .unwrap_or(DEFAULT_MAX_SAMPLING_RATE)
                .max(1),
        }
    }
}

impl FlowHandler for SflowHandler {
    fn parse_datagram(&self, buf: &[u8], _len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
        let receive_time_ns = match get_current_time_ns() {
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
                peer,
                datagram.sequence_number,
                datagram.samples.len()
            );

            let converter = Converter::new(datagram, peer, receive_time_ns, self.max_sampling_rate);
            let valid = filter_and_track_flows(converter.convert(), peer, &self.metrics);
            self.metrics
                .sampling_rate_clamped
                .fetch_add(converter.clamped_rates(), Ordering::Relaxed);
            all_messages.extend(valid);
        }

        all_messages
    }

    fn protocol_name(&self) -> &'static str {
        "sflow"
    }
}
