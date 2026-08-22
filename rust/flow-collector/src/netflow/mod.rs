pub mod converter;

use crate::config::PendingFlowsCacheConfig;
use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use crate::sflow::SflowHandler;
use converter::Converter;
use log::{debug, info, warn};
use netflow_parser::{AutoScopedParser, NetflowParserBuilder, PendingFlowsConfig, TemplateEvent};
use std::collections::HashMap;
use std::net::IpAddr;
use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn make_template_event_callback(
    pending_enabled: bool,
) -> impl Fn(&TemplateEvent) -> Result<(), netflow_parser::TemplateHookError> {
    move |event: &TemplateEvent| {
        use TemplateEvent::*;
        match event {
            Learned {
                template_id,
                protocol,
            } => {
                info!(
                    "Template learned - ID: {:?}, Protocol: {:?}",
                    template_id, protocol
                );
            }
            Collision {
                template_id,
                protocol,
            } => {
                warn!(
                    "Template collision - ID: {:?}, Protocol: {:?}",
                    template_id, protocol
                );
            }
            Evicted {
                template_id,
                protocol,
            } => {
                debug!(
                    "Template evicted - ID: {:?}, Protocol: {:?}",
                    template_id, protocol
                );
            }
            Expired {
                template_id,
                protocol,
            } => {
                debug!(
                    "Template expired - ID: {:?}, Protocol: {:?}",
                    template_id, protocol
                );
            }
            MissingTemplate {
                template_id,
                protocol,
            } => {
                if pending_enabled {
                    debug!(
                        "Missing template - ID: {:?}, Protocol: {:?}. \
                         Pending flow cache enabled; data queued if capacity allows.",
                        template_id, protocol
                    );
                } else {
                    warn!(
                        "Missing template - ID: {:?}, Protocol: {:?}. \
                         Flow data received before template definition - data lost.",
                        template_id, protocol
                    );
                }
            }
            _ => {}
        }
        Ok(())
    }
}

pub struct NetflowHandler {
    parser: Mutex<AutoScopedParser>,
    sampling_rates_by_exporter_sampler_id: Mutex<HashMap<(IpAddr, u64), u64>>,
    default_sampling_rate: u64,
    sampling_rate_overrides: HashMap<IpAddr, u64>,
    sflow_fallback: SflowHandler,
    metrics: Arc<ListenerMetrics>,
}

impl NetflowHandler {
    pub fn new(
        max_templates: usize,
        pending_flows: Option<&PendingFlowsCacheConfig>,
        default_sampling_rate: Option<u64>,
        sampling_rate_overrides: HashMap<IpAddr, u64>,
        metrics: Arc<ListenerMetrics>,
    ) -> Self {
        let pending_enabled = pending_flows.is_some();
        let mut builder = NetflowParserBuilder::default()
            .with_cache_size(max_templates)
            .on_template_event(make_template_event_callback(pending_enabled));

        if let Some(pf) = pending_flows {
            let mut pf_config = PendingFlowsConfig::with_ttl(
                pf.max_pending_flows,
                Duration::from_secs(pf.ttl_secs),
            );
            pf_config.max_entries_per_template = pf.max_entries_per_template;
            pf_config.max_entry_size_bytes = pf.max_entry_size_bytes;
            builder = builder.with_pending_flows(pf_config);
        }

        let parser =
            AutoScopedParser::try_with_builder(builder).expect("failed to build netflow parser");

        Self {
            parser: Mutex::new(parser),
            sampling_rates_by_exporter_sampler_id: Mutex::new(HashMap::new()),
            default_sampling_rate: default_sampling_rate.unwrap_or(1).max(1),
            sampling_rate_overrides,
            sflow_fallback: SflowHandler::new(None, Arc::clone(&metrics)),
            metrics,
        }
    }

    fn fallback_sampling_rate(&self, peer: SocketAddr) -> u64 {
        self.sampling_rate_overrides
            .get(&peer.ip())
            .copied()
            .unwrap_or(self.default_sampling_rate)
            .max(1)
    }
}

impl FlowHandler for NetflowHandler {
    fn parse_datagram(&self, buf: &[u8], _len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
        if is_sflow_datagram(buf) {
            debug!(
                "Detected sFlow datagram on NetFlow listener from {}; routing through sFlow parser",
                peer
            );
            return self.sflow_fallback.parse_datagram(buf, buf.len(), peer);
        }

        let receive_time_ns = match get_current_time_ns() {
            Ok(t) => t,
            Err(e) => {
                warn!("Failed to get current time: {}", e);
                return vec![];
            }
        };

        debug!("Received {} bytes from {}", buf.len(), peer);

        let packets: Vec<_> = {
            let mut parser = self.parser.lock().unwrap();
            match parser.iter_packets_from_source(peer, buf) {
                Ok(iter) => iter.collect(),
                Err(e) => {
                    // The datagram could not be scoped as NetFlow/IPFIX at all,
                    // so it is almost certainly not NetFlow: this port receives
                    // whatever the network sends it. Counted apart from
                    // parse_errors and logged at debug, because a single stray
                    // packet used to pin parse_errors above zero for the
                    // lifetime of the process and make a healthy listener read
                    // as permanently failing in every metrics line.
                    debug!("Undecodable datagram from {} on NetFlow listener: {:?}", peer, e);
                    self.metrics
                        .undecodable_datagrams
                        .fetch_add(1, Ordering::Relaxed);
                    return vec![];
                }
            }
        };

        let mut all_messages = Vec::new();

        for packet_result in packets {
            let packet = match packet_result {
                Ok(p) => p,
                Err(e) => {
                    warn!("Failed to parse NetFlow packet from {}: {:?}", peer, e);
                    self.metrics.parse_errors.fetch_add(1, Ordering::Relaxed);
                    continue;
                }
            };
            debug!("Parsed NetFlow packet {:?}", packet);

            let flow_messages: Vec<FlowMessage> = {
                let fallback_sampling_rate = self.fallback_sampling_rate(peer);
                let mut sampler_rates = self.sampling_rates_by_exporter_sampler_id.lock().unwrap();

                Converter::new(packet, peer, receive_time_ns, fallback_sampling_rate)
                    .convert_with_sampler_rates(&mut sampler_rates)
            };

            let valid = filter_and_track_flows(flow_messages, peer, &self.metrics);
            all_messages.extend(valid);
        }

        all_messages
    }

    fn protocol_name(&self) -> &'static str {
        "netflow"
    }
}

fn is_sflow_datagram(buf: &[u8]) -> bool {
    let Some(header) = buf.get(..4) else {
        return false;
    };

    matches!(
        u32::from_be_bytes(header.try_into().expect("slice length checked")),
        5
    )
}

#[cfg(test)]
mod tests {
    use super::is_sflow_datagram;

    #[test]
    fn detects_sflow_v5_datagram_header() {
        let buf = [0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x01];

        assert!(is_sflow_datagram(&buf));
    }

    #[test]
    fn does_not_treat_netflow_v5_as_sflow() {
        let buf = [0x00, 0x05, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x00];

        assert!(!is_sflow_datagram(&buf));
    }

    #[test]
    fn ignores_short_datagrams() {
        assert!(!is_sflow_datagram(&[0x00, 0x00, 0x00]));
    }
}
