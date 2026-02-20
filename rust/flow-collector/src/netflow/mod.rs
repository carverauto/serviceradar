pub mod converter;

use crate::error::GetCurrentTimeError;
use crate::listener::FlowHandler;
use crate::metrics::ListenerMetrics;
use crate::sflow::converter::flowpb::FlowMessage;
use converter::{Converter, is_valid_flow};
use log::{debug, info, warn};
use netflow_parser::{AutoScopedParser, NetflowParserBuilder, PendingFlowsConfig, TemplateEvent};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::sync::atomic::Ordering;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::config::PendingFlowsCacheConfig;

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

    fn get_current_time_ns() -> Result<u64, GetCurrentTimeError> {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(GetCurrentTimeError::SystemTimeError)?;
        u64::try_from(duration.as_nanos()).map_err(GetCurrentTimeError::TryFromIntError)
    }
}

impl FlowHandler for NetflowHandler {
    fn parse_datagram(&self, buf: &[u8], _len: usize, peer: SocketAddr) -> Vec<FlowMessage> {
        let receive_time_ns = match Self::get_current_time_ns() {
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
                match Converter::new(packet, peer, receive_time_ns).try_into() {
                    Ok(messages) => messages,
                    Err(e) => {
                        warn!("Failed to convert NetFlow packet to protobuf: {:?}", e);
                        continue;
                    }
                };

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
        "netflow"
    }
}
