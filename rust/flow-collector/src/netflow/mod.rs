pub mod converter;

use crate::config::PendingFlowsCacheConfig;
use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use crate::sflow::SflowHandler;
use converter::{Converter, DEFAULT_MAX_SAMPLING_RATE, SamplerRates};
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
    max_sampling_rate: u64,
    sampling_rate_overrides: HashMap<IpAddr, u64>,
    sflow_fallback: SflowHandler,
    metrics: Arc<ListenerMetrics>,
}

impl NetflowHandler {
    // Constructor mirrors the listener config's flat shape; grouping these
    // would add indirection without hiding anything.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        max_templates: usize,
        max_template_fields: usize,
        pending_flows: Option<&PendingFlowsCacheConfig>,
        default_sampling_rate: Option<u64>,
        max_sampling_rate: Option<u64>,
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
            max_sampling_rate: max_sampling_rate
                .unwrap_or(DEFAULT_MAX_SAMPLING_RATE)
                .max(1),
            sampling_rate_overrides,
            // A netflow listener routes sFlow datagrams to this fallback, so
            // it must carry the same ceiling or the knob would not cover its
            // own port.
            sflow_fallback: SflowHandler::new(None, Arc::clone(&metrics), max_sampling_rate),
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
                let clamped_before = sampler_rates.clamped_rates;
                let learned_before = sampler_rates.options_rates_learned;
                let converted = Converter::new(
                    packet,
                    peer,
                    receive_time_ns,
                    fallback_sampling_rate,
                    self.max_sampling_rate,
                )
                .convert_with_sampler_rates(&mut sampler_rates);
                self.metrics
                    .sampler_rate_rejections
                    .fetch_add(sampler_rates.rejected_inserts - before, Ordering::Relaxed);
                self.metrics.sampling_rate_clamped.fetch_add(
                    sampler_rates.clamped_rates - clamped_before,
                    Ordering::Relaxed,
                );
                self.metrics.options_sampling_rates_learned.fetch_add(
                    sampler_rates.options_rates_learned - learned_before,
                    Ordering::Relaxed,
                );
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
            None,
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

    /// NetFlow v5 bytes: 24-octet header then one 48-octet record. v5 carries
    /// no templates, so it reaches the converter under secure defaults.
    fn v5_packet(sampling_interval: u16) -> Vec<u8> {
        let mut packet = Vec::new();
        packet.extend_from_slice(&5u16.to_be_bytes());
        packet.extend_from_slice(&1u16.to_be_bytes()); // count
        for value in [1000u32, 1_893_456_000, 0, 0] {
            packet.extend_from_slice(&value.to_be_bytes());
        }
        packet.push(0); // engine_type
        packet.push(0); // engine_id
        packet.extend_from_slice(&sampling_interval.to_be_bytes());

        packet.extend_from_slice(&[192, 0, 2, 1]); // src
        packet.extend_from_slice(&[192, 0, 2, 2]); // dst
        packet.extend_from_slice(&[0, 0, 0, 0]); // next hop
        packet.extend_from_slice(&1u16.to_be_bytes()); // input
        packet.extend_from_slice(&2u16.to_be_bytes()); // output
        packet.extend_from_slice(&10u32.to_be_bytes()); // packets
        packet.extend_from_slice(&1500u32.to_be_bytes()); // octets
        packet.extend_from_slice(&0u32.to_be_bytes()); // first
        packet.extend_from_slice(&0u32.to_be_bytes()); // last
        packet.extend_from_slice(&1234u16.to_be_bytes()); // src_port
        packet.extend_from_slice(&80u16.to_be_bytes()); // dst_port
        packet.push(0); // pad1
        packet.push(0); // tcp_flags
        packet.push(6); // protocol
        packet.push(0); // tos
        packet.extend_from_slice(&0u16.to_be_bytes()); // src_as
        packet.extend_from_slice(&0u16.to_be_bytes()); // dst_as
        packet.push(0); // src_mask
        packet.push(0); // dst_mask
        packet.extend_from_slice(&0u16.to_be_bytes()); // pad2
        packet
    }

    /// The v5 wire interval reaches 16,383, so any ceiling below that is
    /// reachable from the packet itself -- not only from a misconfigured
    /// fallback. The clamp must therefore be counted like every other, or the
    /// metric operators are told to watch reads zero while rates are rescaled.
    #[test]
    fn v5_sampling_clamps_are_counted() {
        let metrics = Arc::new(ListenerMetrics::new(
            "netflow",
            "127.0.0.1:2055".to_string(),
        ));
        let handler = NetflowHandler::new(
            10,
            100,
            None,
            None,
            Some(100), // ceiling below the v5 wire maximum
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );

        let peer: SocketAddr = "192.0.2.10:9995".parse().expect("addr");
        let messages = handler.parse_datagram(&v5_packet(1000), 0, peer);

        assert_eq!(messages.len(), 1, "expected one v5 flow");
        assert_eq!(
            messages[0].sampling_rate, 100,
            "the declared 1000 must be bounded to the ceiling"
        );
        assert_eq!(
            metrics.sampling_rate_clamped.load(Ordering::Relaxed),
            1,
            "a v5 clamp must reach the metric"
        );
    }

    #[test]
    fn v5_sampling_below_the_ceiling_is_not_counted() {
        let metrics = Arc::new(ListenerMetrics::new(
            "netflow",
            "127.0.0.1:2055".to_string(),
        ));
        let handler = NetflowHandler::new(
            10,
            100,
            None,
            None,
            Some(100_000),
            HashMap::new(),
            Some(2),
            Arc::clone(&metrics),
        );

        let peer: SocketAddr = "192.0.2.10:9995".parse().expect("addr");
        let messages = handler.parse_datagram(&v5_packet(1000), 0, peer);

        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].sampling_rate, 1000);
        assert_eq!(metrics.sampling_rate_clamped.load(Ordering::Relaxed), 0);
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

    /// An information element ID and its encoded value; the value's length is
    /// the template field length.
    type Element = (u16, Vec<u8>);

    fn ie(id: u16, len: usize, value: u64) -> Element {
        (id, value.to_be_bytes()[8 - len..].to_vec())
    }

    /// Synthetic IPFIX message (RFC 7011 section 3) from `(set id, body)` pairs.
    fn ipfix_message(domain: u32, sets: &[(u16, Vec<u8>)]) -> Vec<u8> {
        let length = 16 + sets.iter().map(|(_, body)| 4 + body.len()).sum::<usize>();
        let mut message = Vec::new();
        message.extend_from_slice(&10u16.to_be_bytes());
        message.extend_from_slice(&(length as u16).to_be_bytes());
        for value in [1_893_456_000u32, 1, domain] {
            message.extend_from_slice(&value.to_be_bytes());
        }
        for (set_id, body) in sets {
            message.extend_from_slice(&set_id.to_be_bytes());
            message.extend_from_slice(&((4 + body.len()) as u16).to_be_bytes());
            message.extend_from_slice(body);
        }
        message
    }

    /// A template set (id 2) or, with a scope count, an options template set
    /// (id 3), each followed by one record of that template.
    fn ipfix_template_and_record(
        domain: u32,
        template_id: u16,
        scope_count: Option<u16>,
        fields: &[Element],
    ) -> Vec<u8> {
        let mut template = Vec::new();
        template.extend_from_slice(&template_id.to_be_bytes());
        template.extend_from_slice(&(fields.len() as u16).to_be_bytes());
        if let Some(scope_count) = scope_count {
            template.extend_from_slice(&scope_count.to_be_bytes());
        }
        for (id, value) in fields {
            template.extend_from_slice(&id.to_be_bytes());
            template.extend_from_slice(&(value.len() as u16).to_be_bytes());
        }
        let record = fields.iter().flat_map(|(_, value)| value.clone()).collect();
        let set_id = if scope_count.is_some() { 3 } else { 2 };
        ipfix_message(domain, &[(set_id, template), (template_id, record)])
    }

    /// Options record scoped to its observation domain (IE 149).
    fn ipfix_sampling_options(domain: u32, options: &[Element]) -> Vec<u8> {
        let mut fields = vec![ie(149, 4, domain.into())];
        fields.extend_from_slice(options);
        ipfix_template_and_record(domain, 300, Some(1), &fields)
    }

    /// One flow record whose template holds only addresses and counters plus
    /// `extra`. Distinct `extra` shapes must use distinct template ids.
    fn ipfix_flow(domain: u32, template_id: u16, extra: &[Element]) -> Vec<u8> {
        let mut fields = vec![
            ie(8, 4, u64::from(u32::from_be_bytes([192, 0, 2, 10]))),
            ie(12, 4, u64::from(u32::from_be_bytes([198, 51, 100, 20]))),
            ie(1, 4, 1500),
            ie(2, 4, 3),
        ];
        fields.extend_from_slice(extra);
        ipfix_template_and_record(domain, template_id, None, &fields)
    }

    fn netflow_handler(
        default_sampling_rate: Option<u64>,
        max_sampling_rate: Option<u64>,
        metrics: &Arc<ListenerMetrics>,
    ) -> NetflowHandler {
        NetflowHandler::new(
            128,
            100,
            None,
            default_sampling_rate,
            max_sampling_rate,
            HashMap::new(),
            None,
            Arc::clone(metrics),
        )
    }

    fn decoded_rate(handler: &NetflowHandler, packet: &[u8], peer: SocketAddr) -> u64 {
        let decoded = handler.parse_datagram(packet, packet.len(), peer);
        assert_eq!(decoded.len(), 1, "expected exactly one flow");
        decoded[0].sampling_rate
    }

    /// An exporter that samples 1-in-N declares N once, in an options record,
    /// instead of in every flow record.
    #[test]
    fn ipfix_options_declared_sampling_applies_to_flows_without_a_rate() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:4739".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.1:4739".parse().unwrap();

        assert_eq!(decoded_rate(&handler, &ipfix_flow(7, 256, &[]), peer), 5);

        // selectorId, selectorAlgorithm (3 = random n-out-of-N packet
        // sampling), samplingSize 1 of samplingPopulation 512.
        let options = ipfix_sampling_options(
            7,
            &[ie(302, 8, 9), ie(304, 1, 3), ie(309, 4, 1), ie(310, 4, 512)],
        );
        assert!(
            handler
                .parse_datagram(&options, options.len(), peer)
                .is_empty()
        );

        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 256, &[]), peer),
            512,
            "options-declared rate beats the configured default"
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 257, &[ie(34, 4, 10)]), peer),
            10,
            "a rate carried by the record itself wins"
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(8, 256, &[]), peer),
            5,
            "another observation domain of the same exporter is unaffected"
        );
        assert_eq!(
            metrics
                .options_sampling_rates_learned
                .load(Ordering::Relaxed),
            1
        );
        handler.parse_datagram(&options, options.len(), peer);
        assert_eq!(
            metrics
                .options_sampling_rates_learned
                .load(Ordering::Relaxed),
            1,
            "refreshing the same rate does not count as another learned rate"
        );
    }

    /// Options scoped to an interface apply to that interface only.
    #[test]
    fn ipfix_options_interface_scope_applies_to_matching_flows() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:4739".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.8:4739".parse().unwrap();
        let ingress = ipfix_template_and_record(7, 301, Some(1), &[ie(10, 4, 10), ie(34, 4, 100)]);
        let egress = ipfix_template_and_record(7, 302, Some(1), &[ie(14, 4, 20), ie(34, 4, 1000)]);
        handler.parse_datagram(&ingress, ingress.len(), peer);
        handler.parse_datagram(&egress, egress.len(), peer);

        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 258, &[ie(10, 4, 10)]), peer),
            100,
            "ingress 10 keeps its own rate"
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 258, &[ie(10, 4, 20)]), peer),
            1000,
            "the egress-scoped index applies to a flow that enters that interface"
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 259, &[ie(10, 4, 99)]), peer),
            5,
            "an interface with no options rate uses the configured default"
        );

        handler.parse_datagram(&ingress, ingress.len(), peer);
        assert_eq!(
            metrics
                .options_sampling_rates_learned
                .load(Ordering::Relaxed),
            2,
            "re-announcing interface 10 at 1:100 does not count again"
        );

        let domain = ipfix_sampling_options(7, &[ie(34, 4, 50)]);
        handler.parse_datagram(&domain, domain.len(), peer);
        let cases: [(&str, u16, Vec<Element>, u64); 5] = [
            ("input interface 10", 258, vec![ie(10, 4, 10)], 100),
            ("input interface 20", 258, vec![ie(10, 4, 20)], 1000),
            (
                "output interface 20 when the input has no entry",
                260,
                vec![ie(10, 4, 99), ie(14, 4, 20)],
                1000,
            ),
            (
                "unmatched interface falls back to the domain rate",
                258,
                vec![ie(10, 4, 30)],
                50,
            ),
            (
                "no interface falls back to the domain rate",
                256,
                vec![],
                50,
            ),
        ];
        for (case, template, extra, expected) in cases {
            assert_eq!(
                decoded_rate(&handler, &ipfix_flow(7, template, &extra), peer),
                expected,
                "{case}"
            );
        }
        assert_eq!(
            metrics
                .options_sampling_rates_learned
                .load(Ordering::Relaxed),
            3
        );
    }

    /// v9 interface scope (type 2) is the same key as an IPFIX interface scope.
    #[test]
    fn v9_options_interface_scope_applies_to_matching_flows() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.6:2055".parse().unwrap();
        let words = |values: &[u16]| -> Vec<u8> {
            values.iter().flat_map(|word| word.to_be_bytes()).collect()
        };
        let flowset = |id: u16, body: &[u8]| {
            let mut set = id.to_be_bytes().to_vec();
            set.extend_from_slice(&((4 + body.len()) as u16).to_be_bytes());
            set.extend_from_slice(body);
            set
        };
        let message = |flowsets: &[Vec<u8>]| {
            let mut packet = Vec::new();
            packet.extend_from_slice(&9u16.to_be_bytes());
            packet.extend_from_slice(&1u16.to_be_bytes());
            for value in [1000u32, 1_893_456_000, 1, 3] {
                packet.extend_from_slice(&value.to_be_bytes());
            }
            for set in flowsets {
                packet.extend_from_slice(set);
            }
            packet
        };
        let interface_options = |template: u16, interface: u16, rate: u16| {
            message(&[
                flowset(1, &words(&[template, 4, 4, 2, 4, 34, 4])),
                flowset(template, &words(&[0, interface, 0, rate])),
            ])
        };
        for (template, interface, rate) in [(301, 10, 100), (302, 20, 1000)] {
            let packet = interface_options(template, interface, rate);
            assert!(
                handler
                    .parse_datagram(&packet, packet.len(), peer)
                    .is_empty()
            );
        }

        let flow = |input: u32, output: u32| {
            let mut record = Vec::new();
            for value in [1500u32, 3, input, output] {
                record.extend_from_slice(&value.to_be_bytes());
            }
            v9_packet(3, Some(&[(1, 4), (2, 4), (10, 4), (14, 4)]), &record)
        };
        assert_eq!(decoded_rate(&handler, &flow(10, 1), peer), 100);
        assert_eq!(decoded_rate(&handler, &flow(20, 1), peer), 1000);
        assert_eq!(decoded_rate(&handler, &flow(99, 1), peer), 5);

        // System scope, sampling interval 50, no sampler id: the domain rate.
        let domain = message(&[
            flowset(1, &words(&[303, 4, 4, 1, 4, 34, 4])),
            flowset(303, &words(&[0, 1, 0, 50])),
        ]);
        handler.parse_datagram(&domain, domain.len(), peer);
        assert_eq!(decoded_rate(&handler, &flow(99, 1), peer), 50);
        assert_eq!(
            decoded_rate(&handler, &flow(99, 20), peer),
            1000,
            "output matches when the input interface has no entry"
        );
        assert_eq!(decoded_rate(&handler, &flow(10, 20), peer), 100);
    }

    /// Each RFC 5477 / RFC 7015 way of declaring a sampling rate in options.
    #[test]
    fn ipfix_options_sampling_rate_derivation() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:4739".into()));
        let handler = netflow_handler(None, Some(4096), &metrics);
        let peer: SocketAddr = "192.0.2.2:4739".parse().unwrap();
        let cases: [(&str, Vec<Element>, u64); 6] = [
            ("samplingInterval", vec![ie(34, 4, 256)], 256),
            ("samplerRandomInterval", vec![ie(50, 4, 100)], 100),
            (
                "samplingPacketInterval selected, samplingPacketSpace skipped",
                vec![ie(305, 4, 1), ie(306, 4, 99)],
                100,
            ),
            (
                "samplingSize out of samplingPopulation",
                vec![ie(309, 4, 2), ie(310, 4, 2048)],
                1024,
            ),
            (
                "samplingProbability",
                vec![(311, (1.0f64 / 512.0).to_be_bytes().to_vec())],
                512,
            ),
            (
                "rate above max_sampling_rate",
                vec![ie(34, 4, 1_000_000)],
                4096,
            ),
        ];
        for (domain, (case, options, expected)) in (1u32..).zip(cases) {
            let packet = ipfix_sampling_options(domain, &options);
            handler.parse_datagram(&packet, packet.len(), peer);
            assert_eq!(
                decoded_rate(&handler, &ipfix_flow(domain, 256, &[]), peer),
                expected,
                "{case}"
            );
        }
        assert_eq!(metrics.sampling_rate_clamped.load(Ordering::Relaxed), 1);
    }

    /// Flow selection and hash or property filtering export whole flows with
    /// complete counters, so the selection ratio they declare must not scale
    /// the records: each flow publishes rate 1, not the fallback and not N.
    #[test]
    fn ipfix_options_selection_of_whole_flows_is_not_scaled() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:4739".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.5:4739".parse().unwrap();
        let cases: [(&str, Vec<Element>, Vec<Element>); 4] = [
            (
                "flowSelectorAlgorithm 3, samplingSize 1 of samplingPopulation 512",
                vec![ie(302, 8, 4), ie(390, 1, 3), ie(309, 4, 1), ie(310, 4, 512)],
                vec![ie(302, 8, 4)],
            ),
            (
                "selectorAlgorithm 6 (hash-based filtering), samplingInterval 512",
                vec![ie(304, 1, 6), ie(34, 4, 512)],
                vec![],
            ),
            (
                "hashSelectedRangeMax with samplingInterval 512 and no algorithm",
                vec![ie(332, 8, 127), ie(34, 4, 512)],
                vec![],
            ),
            (
                "samplingFlowInterval selected, samplingFlowSpacing skipped",
                vec![ie(396, 4, 1), ie(397, 4, 511)],
                vec![],
            ),
        ];
        for (domain, (case, options, flow)) in (1u32..).zip(cases) {
            let packet = ipfix_sampling_options(domain, &options);
            handler.parse_datagram(&packet, packet.len(), peer);
            assert_eq!(
                decoded_rate(&handler, &ipfix_flow(domain, 256, &flow), peer),
                1,
                "{case}"
            );
        }

        // A selector that switches from packet sampling to flow selection.
        let packet_sampling = ipfix_sampling_options(
            9,
            &[ie(302, 8, 4), ie(304, 1, 3), ie(309, 4, 1), ie(310, 4, 512)],
        );
        handler.parse_datagram(&packet_sampling, packet_sampling.len(), peer);
        let flow = ipfix_flow(9, 256, &[ie(302, 8, 4)]);
        assert_eq!(decoded_rate(&handler, &flow, peer), 512);
        let flow_selection = ipfix_sampling_options(
            9,
            &[ie(302, 8, 4), ie(390, 1, 3), ie(309, 4, 1), ie(310, 4, 512)],
        );
        handler.parse_datagram(&flow_selection, flow_selection.len(), peer);
        assert_eq!(
            decoded_rate(&handler, &flow, peer),
            1,
            "flow selection replaces the selector's packet sampling rate"
        );
    }

    /// Several selectors with different rates: a flow naming its selector gets
    /// that selector's rate, and a flow naming none cannot be attributed.
    #[test]
    fn ipfix_options_selectors_resolve_by_selector_id() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:4739".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.3:4739".parse().unwrap();
        for (selector, interval) in [(1, 100), (2, 400)] {
            let packet = ipfix_sampling_options(7, &[ie(302, 8, selector), ie(34, 4, interval)]);
            handler.parse_datagram(&packet, packet.len(), peer);
        }

        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 256, &[ie(302, 8, 2)]), peer),
            400
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 256, &[ie(302, 8, 1)]), peer),
            100
        );
        assert_eq!(
            decoded_rate(&handler, &ipfix_flow(7, 257, &[]), peer),
            5,
            "two declared rates leave a selector-less flow on the fallback"
        );
    }

    /// NetFlow v9 (RFC 3954 section 6) declares a random sampler in an
    /// options record scoped to the system.
    #[test]
    fn v9_options_declared_sampling_applies_to_flows_without_a_rate() {
        let metrics = Arc::new(ListenerMetrics::new("netflow", "0.0.0.0:2055".into()));
        let handler = netflow_handler(Some(5), None, &metrics);
        let peer: SocketAddr = "192.0.2.4:2055".parse().unwrap();
        let flowset = |id: u16, words: &[u16], tail: &[u8]| {
            let mut body: Vec<u8> = words.iter().flat_map(|word| word.to_be_bytes()).collect();
            body.extend_from_slice(tail);
            let mut set = id.to_be_bytes().to_vec();
            set.extend_from_slice(&((4 + body.len()) as u16).to_be_bytes());
            set.extend_from_slice(&body);
            set
        };
        let message = |records: u16, flowsets: &[Vec<u8>]| {
            let mut packet = Vec::new();
            packet.extend_from_slice(&9u16.to_be_bytes());
            packet.extend_from_slice(&records.to_be_bytes());
            for value in [1000u32, 1_893_456_000, 1, 3] {
                packet.extend_from_slice(&value.to_be_bytes());
            }
            for set in flowsets {
                packet.extend_from_slice(set);
            }
            packet
        };
        // Options template 300: scope System (1) of 4 octets; FLOW_SAMPLER_ID
        // (48), FLOW_SAMPLER_MODE (49), FLOW_SAMPLER_RANDOM_INTERVAL (50).
        let options = message(
            1,
            &[
                flowset(1, &[300, 4, 12, 1, 4, 48, 2, 49, 2, 50, 4], &[]),
                flowset(300, &[0, 3, 4, 2, 0, 512], &[]),
            ],
        );
        assert!(
            handler
                .parse_datagram(&options, options.len(), peer)
                .is_empty()
        );

        // Template 256: IN_BYTES (1), IN_PKTS (2); 257 adds FLOW_SAMPLER_ID.
        let mut counters = 1500u32.to_be_bytes().to_vec();
        counters.extend_from_slice(&3u32.to_be_bytes());
        let mut with_sampler = counters.clone();
        with_sampler.extend_from_slice(&4u16.to_be_bytes());
        let flows = message(
            4,
            &[
                flowset(0, &[256, 2, 1, 4, 2, 4, 257, 3, 1, 4, 2, 4, 48, 2], &[]),
                flowset(256, &[], &counters),
                flowset(257, &[], &with_sampler),
            ],
        );
        let decoded = handler.parse_datagram(&flows, flows.len(), peer);
        let rates: Vec<u64> = decoded.iter().map(|flow| flow.sampling_rate).collect();
        assert_eq!(rates, [512, 512]);
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
