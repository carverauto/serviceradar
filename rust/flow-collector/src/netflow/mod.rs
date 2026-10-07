pub mod converter;

use crate::config::PendingFlowsCacheConfig;
use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use crate::sflow::SflowHandler;
use converter::{Converter, SamplerRates};
use log::{debug, info, warn};
use netflow_parser::scoped_parser::{DEFAULT_MAX_SOURCES, ScopingInfo, extract_scoping_info};
use netflow_parser::{
    AutoScopedParser, IpfixSourceKey, NetflowParserBuilder, PendingFlowsConfig, TemplateEvent,
    V9SourceKey,
};
use std::collections::{BTreeMap, HashMap};
use std::net::IpAddr;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU64, Ordering};
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
            Restored {
                template_id,
                protocol,
            } => {
                info!(
                    "Template restored from secondary store - ID: {:?}, Protocol: {:?}",
                    template_id, protocol
                );
            }
            _ => {}
        }
        Ok(())
    }
}

pub struct NetflowHandler {
    parser: Arc<Mutex<AutoScopedParser>>,
    sampling_rates_by_exporter_sampler_id: Mutex<SamplerRates>,
    sources: Mutex<SourceAdmission>,
    max_sources: usize,
    live_sources: AtomicU64,
    default_sampling_rate: u64,
    sampling_rate_overrides: HashMap<IpAddr, u64>,
    sflow_fallback: SflowHandler,
    metrics: Arc<ListenerMetrics>,
}

impl NetflowHandler {
    pub fn new(
        max_templates: usize,
        max_template_fields: usize,
        pending_flows: Option<&PendingFlowsCacheConfig>,
        default_sampling_rate: Option<u64>,
        sampling_rate_overrides: HashMap<IpAddr, u64>,
        max_sources: Option<usize>,
        metrics: Arc<ListenerMetrics>,
    ) -> Self {
        let pending_enabled = pending_flows.is_some();
        let mut builder = NetflowParserBuilder::default()
            .with_cache_size(max_templates)
            .with_max_field_count(max_template_fields)
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
        let parser = if let Some(max) = max_sources {
            parser
                .with_max_sources(max)
                .expect("max_sources must be non-zero")
        } else {
            parser
        };
        let parser = Arc::new(Mutex::new(parser));

        Self {
            parser,
            live_sources: AtomicU64::new(0),
            sampling_rates_by_exporter_sampler_id: Mutex::new(SamplerRates::default()),
            sources: Mutex::new(SourceAdmission::default()),
            max_sources: max_sources.unwrap_or(DEFAULT_MAX_SOURCES),
            default_sampling_rate: default_sampling_rate.unwrap_or(1).max(1),
            sampling_rate_overrides,
            sflow_fallback: SflowHandler::new(None, Arc::clone(&metrics)),
            metrics,
        }
    }

    fn admit_source(&self, parser: &mut AutoScopedParser, peer: SocketAddr, buf: &[u8]) {
        let Some(source) = SourceId::from_datagram(peer, buf) else {
            return;
        };
        let mut sources = self.sources.lock().unwrap();
        let Some((removed, creator_owned)) = sources.admit(source, peer.ip(), self.max_sources)
        else {
            return;
        };
        // Pressure removes only the in-process parser. It must not
        // masquerade as an exporter-requested shared withdrawal.
        self.sampling_rates_by_exporter_sampler_id
            .lock()
            .unwrap()
            .remove_source(&removed);
        let retired = match removed {
            SourceId::Ipfix(key) => parser.remove_ipfix_source(&key),
            SourceId::V9(key) => parser.remove_v9_source(&key),
            SourceId::Legacy(addr) => parser.remove_legacy_source(&addr),
        };
        drop(retired);
        let counter = if creator_owned {
            &self.metrics.source_creator_evictions
        } else {
            &self.metrics.source_global_evictions
        };
        counter.fetch_add(1, Ordering::Relaxed);
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
            self.admit_source(&mut parser, peer, buf);
            let packets = match parser.iter_packets_from_source(peer, buf) {
                Ok(iter) => iter.collect(),
                Err(e) => {
                    // The datagram could not be scoped as NetFlow/IPFIX at all,
                    // so it is almost certainly not NetFlow: this port receives
                    // whatever the network sends it. Counted apart from
                    // parse_errors and logged at debug, because a single stray
                    // packet used to pin parse_errors above zero for the
                    // lifetime of the process and make a healthy listener read
                    // as permanently failing in every metrics line.
                    debug!(
                        "Undecodable datagram from {} on NetFlow listener: {:?}",
                        peer, e
                    );
                    self.metrics
                        .undecodable_datagrams
                        .fetch_add(1, Ordering::Relaxed);
                    return vec![];
                }
            };
            let count = parser.source_count() as u64;
            let previous = self.live_sources.swap(count, Ordering::Relaxed);
            if count >= previous {
                self.metrics
                    .source_count
                    .fetch_add(count - previous, Ordering::Relaxed);
            } else {
                self.metrics
                    .source_count
                    .fetch_sub(previous - count, Ordering::Relaxed);
            }
            packets
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

                let before = sampler_rates.rejected_inserts;
                let converted =
                    Converter::new(packet, peer, receive_time_ns, fallback_sampling_rate)
                        .convert_with_sampler_rates(&mut sampler_rates);
                self.metrics
                    .sampler_rate_rejections
                    .fetch_add(sampler_rates.rejected_inserts - before, Ordering::Relaxed);
                converted
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

/// Exact identities for all three AutoScopedParser scoping paths.
#[derive(Hash, PartialEq, Eq, Clone, Debug)]
enum SourceId {
    Ipfix(IpfixSourceKey),
    V9(V9SourceKey),
    Legacy(SocketAddr),
}

impl SourceId {
    fn from_datagram(addr: SocketAddr, bytes: &[u8]) -> Option<Self> {
        match extract_scoping_info(bytes) {
            ScopingInfo::IPFix {
                observation_domain_id,
            } => Some(Self::Ipfix(IpfixSourceKey {
                addr,
                observation_domain_id,
            })),
            ScopingInfo::V9 { source_id } => Some(Self::V9(V9SourceKey { addr, source_id })),
            ScopingInfo::Legacy => Some(Self::Legacy(addr)),
            _ => None,
        }
    }
}

/// Exact transport/domain identities stay in the parser. Pressure ownership
/// groups by IP so changing source ports cannot evade creator preference.
#[derive(Default)]
struct SourceAdmission {
    sequence: u128,
    entries: HashMap<SourceId, (IpAddr, u128)>,
    oldest: BTreeMap<u128, SourceId>,
    by_creator: HashMap<IpAddr, BTreeMap<u128, SourceId>>,
}

impl SourceAdmission {
    fn remove(&mut self, source: &SourceId) {
        if let Some((creator, order)) = self.entries.remove(source) {
            self.oldest.remove(&order);
            let peers = self.by_creator.get_mut(&creator).expect("tracked creator");
            peers.remove(&order);
            if peers.is_empty() {
                self.by_creator.remove(&creator);
            }
        }
    }

    fn admit(
        &mut self,
        source: SourceId,
        creator: IpAddr,
        limit: usize,
    ) -> Option<(SourceId, bool)> {
        let evicted = if !self.entries.contains_key(&source) && self.entries.len() >= limit {
            let preferred = self
                .by_creator
                .get(&creator)
                .and_then(|entries| entries.first_key_value());
            let (victim, creator_owned) = if let Some((_, victim)) = preferred {
                (victim.clone(), true)
            } else {
                (
                    self.oldest
                        .first_key_value()
                        .expect("nonzero source limit")
                        .1
                        .clone(),
                    false,
                )
            };
            self.remove(&victim);
            Some((victim, creator_owned))
        } else {
            None
        };
        self.remove(&source);
        self.sequence += 1;
        self.entries
            .insert(source.clone(), (creator, self.sequence));
        self.oldest.insert(self.sequence, source.clone());
        self.by_creator
            .entry(creator)
            .or_default()
            .insert(self.sequence, source);
        evicted
    }
}

impl Drop for NetflowHandler {
    fn drop(&mut self) {
        self.metrics
            .source_count
            .fetch_sub(self.live_sources.load(Ordering::Relaxed), Ordering::Relaxed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::ListenerMetrics;

    // Synthetic NetFlow v9 bytes assembled from the wire specification.
    fn v9_packet(domain: u32, template: Option<&[(u16, u16)]>, records: &[u8]) -> Vec<u8> {
        let mut packet = Vec::new();
        packet.extend_from_slice(&9u16.to_be_bytes());
        packet
            .extend_from_slice(&u16::from(template.is_some() || !records.is_empty()).to_be_bytes());
        for value in [1000u32, 1_893_456_000, 1, domain] {
            packet.extend_from_slice(&value.to_be_bytes());
        }
        if let Some(fields) = template {
            packet.extend_from_slice(&0u16.to_be_bytes());
            packet.extend_from_slice(&(8u16 + 4 * fields.len() as u16).to_be_bytes());
            packet.extend_from_slice(&256u16.to_be_bytes());
            packet.extend_from_slice(&(fields.len() as u16).to_be_bytes());
            for (kind, length) in fields {
                packet.extend_from_slice(&kind.to_be_bytes());
                packet.extend_from_slice(&length.to_be_bytes());
            }
        }
        if !records.is_empty() {
            packet.extend_from_slice(&256u16.to_be_bytes());
            packet.extend_from_slice(&(4u16 + records.len() as u16).to_be_bytes());
            packet.extend_from_slice(records);
        }
        packet
    }

    #[test]
    fn source_churn_preserves_other_exporters_templates() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let handler = NetflowHandler::new(
            128,
            10_000,
            None,
            None,
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );
        let legitimate: SocketAddr = "192.0.2.1:2055".parse().unwrap();
        let noisy: SocketAddr = "198.51.100.1:2055".parse().unwrap();
        let learned = v9_packet(1, Some(&[(1, 4)]), &111u32.to_be_bytes());
        assert_eq!(
            handler.parse_datagram(&learned, learned.len(), legitimate)[0].bytes,
            111
        );
        let noisy_template = v9_packet(10, Some(&[(1, 4)]), &222u32.to_be_bytes());
        assert_eq!(
            handler.parse_datagram(&noisy_template, noisy_template.len(), noisy)[0].bytes,
            222
        );
        // Changing both domain and port still belongs to the same creator IP.
        for domain in 11..40 {
            let peer = SocketAddr::new(noisy.ip(), 2055 + domain as u16);
            let packet = v9_packet(domain, None, &[]);
            handler.parse_datagram(&packet, packet.len(), peer);
            assert_eq!(handler.parser.lock().unwrap().source_count(), 2);
        }
        let data = v9_packet(1, None, &333u32.to_be_bytes());
        let decoded = handler.parse_datagram(&data, data.len(), legitimate);
        assert_eq!(
            decoded.len(),
            1,
            "unrelated exporter lost its learned template"
        );
        assert_eq!(decoded[0].bytes, 333);
        assert_eq!(metrics.source_creator_evictions.load(Ordering::Relaxed), 29);
        assert_eq!(metrics.source_global_evictions.load(Ordering::Relaxed), 0);
        // A genuinely new creator still has a bounded global-LRU fallback.
        let new_peer: SocketAddr = "203.0.113.1:2055".parse().unwrap();
        handler.parse_datagram(&data, data.len(), new_peer);
        assert_eq!(handler.parser.lock().unwrap().source_count(), 2);
        assert_eq!(metrics.source_global_evictions.load(Ordering::Relaxed), 1);
    }

    #[test]
    fn sampler_state_is_bounded_without_overriding_record_rates_or_existing_updates() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let handler = NetflowHandler::new(
            128,
            10_000,
            None,
            Some(7),
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );
        let peer: SocketAddr = "192.0.2.1:2055".parse().unwrap();
        let template = v9_packet(1, Some(&[(48, 4), (34, 4), (1, 4)]), &[]);
        handler.parse_datagram(&template, template.len(), peer);
        for batch in 0..64u32 {
            let mut records = Vec::new();
            for id in (batch * 1024 + 1)..=(batch + 1) * 1024 {
                for value in [id, 17, 3] {
                    records.extend_from_slice(&value.to_be_bytes());
                }
            }
            let packet = v9_packet(1, None, &records);
            let decoded = handler.parse_datagram(&packet, packet.len(), peer);
            assert_eq!(decoded.len(), 1024);
            assert!(decoded.iter().all(|flow| flow.sampling_rate == 17));
        }
        let lookup = |id: u32, rate: u32| {
            let mut fields = Vec::new();
            for value in [id, rate, 3] {
                fields.extend_from_slice(&value.to_be_bytes());
            }
            let packet = v9_packet(1, None, &fields);
            handler.parse_datagram(&packet, packet.len(), peer)[0].sampling_rate
        };
        assert_eq!(
            lookup(65_537, 19),
            19,
            "record rate wins even when it cannot be cached"
        );
        assert_eq!(
            lookup(65_537, 0),
            7,
            "unknown sampler uses configured fallback"
        );
        assert_eq!(
            lookup(1, 31),
            31,
            "existing sampler updates still work at capacity"
        );
        assert_eq!(lookup(1, 0), 31, "later records reuse the updated rate");
        assert_eq!(metrics.sampler_rate_rejections.load(Ordering::Relaxed), 1);
        assert_eq!(
            handler
                .sampling_rates_by_exporter_sampler_id
                .lock()
                .unwrap()
                .entry_count,
            65_536
        );
    }

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

    #[test]
    fn template_exceeding_max_template_fields_is_rejected() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        // Handler with tight field limit of 3 fields per template
        let handler_bounded = NetflowHandler::new(
            128,
            3,
            None,
            None,
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );
        let peer: SocketAddr = "192.0.2.1:2055".parse().unwrap();

        // 4 fields: exceeds the limit of 3
        let four_fields = [(48u16, 4u16), (34, 4), (2, 4), (1, 4)];
        let packet_four = v9_packet(1, Some(&four_fields), &[]);
        handler_bounded.parse_datagram(&packet_four, packet_four.len(), peer);

        // Subsequent data packet for template 256 cannot be decoded because template was rejected
        let mut record = Vec::new();
        for value in [1u32, 10, 1, 100] {
            record.extend_from_slice(&value.to_be_bytes());
        }
        let data_packet = v9_packet(1, None, &record);
        let decoded = handler_bounded.parse_datagram(&data_packet, data_packet.len(), peer);
        assert!(
            decoded.is_empty(),
            "template with 4 fields should be rejected when max_template_fields is 3"
        );

        // Handler with field limit of 4 fields accepts the same template
        let handler_sufficient = NetflowHandler::new(
            128,
            4,
            None,
            None,
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );
        handler_sufficient.parse_datagram(&packet_four, packet_four.len(), peer);
        let decoded = handler_sufficient.parse_datagram(&data_packet, data_packet.len(), peer);
        assert_eq!(
            decoded.len(),
            1,
            "template with 4 fields should be accepted when max_template_fields is 4"
        );
        assert_eq!(decoded[0].bytes, 100);
    }
}
