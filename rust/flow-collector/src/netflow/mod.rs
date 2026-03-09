pub mod converter;

use crate::config::PendingFlowsCacheConfig;
use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use converter::Converter;
use log::{debug, info, warn};
use netflow_parser::{AutoScopedParser, NetflowParserBuilder, PendingFlowsConfig, TemplateEvent};
use std::net::SocketAddr;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn make_template_event_callback(pending_enabled: bool) -> impl Fn(&TemplateEvent) {
    move |event: &TemplateEvent| {
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
                if pending_enabled {
                    debug!(
                        "Missing template - ID: {}, Protocol: {:?}. \
                         Pending flow cache enabled; data queued if capacity allows.",
                        template_id, protocol
                    );
                } else {
                    warn!(
                        "Missing template - ID: {}, Protocol: {:?}. \
                         Flow data received before template definition - data lost.",
                        template_id, protocol
                    );
                }
            }
        }
    }
}

pub struct NetflowHandler {
    parser: Mutex<AutoScopedParser>,
    metrics: Arc<ListenerMetrics>,
}

impl NetflowHandler {
    pub fn new(
        max_templates: usize,
        pending_flows: Option<&PendingFlowsCacheConfig>,
        metrics: Arc<ListenerMetrics>,
    ) -> Self {
        let pending_enabled = pending_flows.is_some();
        let mut builder = NetflowParserBuilder::default()
            .with_cache_size(max_templates)
            .on_template_event(make_template_event_callback(pending_enabled));

        if let Some(pf) = pending_flows {
            builder = builder.with_pending_flows(PendingFlowsConfig {
                max_pending_flows: pf.max_pending_flows,
                max_entries_per_template: pf.max_entries_per_template,
                max_entry_size_bytes: pf.max_entry_size_bytes,
                ttl: Some(Duration::from_secs(pf.ttl_secs)),
            });
        }

        let parser = AutoScopedParser::with_builder(builder);

        Self {
            parser: Mutex::new(parser),
            metrics,
        }
    }
}

impl FlowHandler for NetflowHandler {
    fn parse_datagram(&self, buf: &[u8], _len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
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
            parser.iter_packets_from_source(peer, buf).collect()
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

            let flow_messages: Vec<FlowMessage> =
                Converter::new(packet, peer, receive_time_ns).into();

            let valid = filter_and_track_flows(flow_messages, peer, &self.metrics);
            all_messages.extend(valid);
        }

        all_messages
    }

    fn protocol_name(&self) -> &'static str {
        "netflow"
    }
}
