use super::SourceId;
use crate::flowpb;
use log::debug;
use netflow_parser::NetflowPacket;
use netflow_parser::protocol::ProtocolTypes;
use netflow_parser::static_versions::v5::V5;
use netflow_parser::variable_versions::field_value::{DataNumber, FieldValue};
use netflow_parser::variable_versions::ipfix::IPFixFieldPair;
use netflow_parser::variable_versions::ipfix::lookup::ReverseInformationElement;
use netflow_parser::variable_versions::ipfix::lookup::{IANAIPFixField, IPFixField};
use netflow_parser::variable_versions::v9::ScopeDataField;
use netflow_parser::variable_versions::v9::lookup::V9Field;
use netflow_parser::{IpfixSourceKey, V9SourceKey};
use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

pub const MAX_SAMPLER_RATE_ENTRIES: usize = 65_536;

/// How long a selector declaration still votes on the domain rate.
///
/// NetFlow options refreshes are commonly 30 minutes. The extra half hour
/// keeps one delayed refresh from retiring a selector that is still in use.
/// A selector silent for the whole window no longer affects flows that name
/// no selector; the selectors refreshed inside the window do.
pub const OPTIONS_REFRESH_WINDOW: Duration = Duration::from_secs(60 * 60);

/// Selector declarations kept per source when computing the domain rate.
///
/// Further selectors from that source are rejected and do not vote. A flow
/// that names one still uses the sampler rate stored for it.
const MAX_SELECTORS_PER_SOURCE: usize = 256;

/// Ceiling applied to any exporter-declared sampling rate before publication.
///
/// Exporter-declared sampling fields are unauthenticated wire input, and every
/// IPFIX/v9 sampling field decodes to a full `u64`. `samplingProbability` is
/// worse: a probability of `1e-300` inverts to roughly `1e300`, and a saturating
/// `as u64` turns that into `u64::MAX`. Because downstream analytics multiply
/// byte and packet counts by this rate, an absurd value inflates a single flow
/// into fabricated volume.
///
/// 1:1,000,000 is already far past operational practice -- 1:10,000 is
/// considered aggressive -- so real exporters never reach this bound. Operators
/// who need more can raise `max_sampling_rate` per listener.
pub const DEFAULT_MAX_SAMPLING_RATE: u64 = 1_000_000;

/// Sampling rates exporters declared, per exporter source (address plus IPFIX
/// observation domain or v9 source ID).
///
/// Rates come from flow records that carry both a sampler ID and a rate, and
/// from options data records (RFC 7011 section 3.4.2.2, RFC 3954 section 6),
/// which is how many sampling exporters declare their rate instead of
/// repeating it in every flow record. The state lives only in memory: after a
/// restart, or when the source is evicted, it is learned again from the
/// exporter's next options refresh, as its templates are.
#[derive(Default)]
pub struct SamplerRates {
    pub(super) entries: HashMap<SourceId, HashMap<u64, u64>>,
    pub(super) entry_count: usize,
    /// Options rates for a source: the domain rate, per-interface rates, and
    /// selector declarations with the time they were last seen. Bounded by
    /// `MAX_SAMPLER_RATE_ENTRIES` sources. Interface rates share `entry_count`
    /// with named samplers.
    domain_rates: HashMap<SourceId, SourceOptions>,
    pub(super) rejected_inserts: u64,
    /// Rates clamped to the configured ceiling. Drained by the caller into
    /// `ListenerMetrics::sampling_rate_clamped`, mirroring `rejected_inserts`.
    pub(super) clamped_rates: u64,
    /// Options rates newly stored or changed. A refresh of the same rate and
    /// a rejected insert are not counted. Drained by the caller into
    /// `ListenerMetrics::options_sampling_rates_learned`.
    pub(super) options_rates_learned: u64,
}

/// Options-declared rates for one exporter source.
#[derive(Default)]
struct SourceOptions {
    /// System or observation-domain scope, for flows with no closer match.
    domain: Option<u64>,
    /// Interface scope (IPFIX ingress/egress, v9 interface): ifIndex to rate.
    interfaces: HashMap<u32, u64>,
    /// Selector id to the rate and receive time of its last options declaration.
    selectors: HashMap<u64, SelectorDecl>,
    /// Agreement of the selectors inside the refresh window.
    consensus: SelectorConsensus,
}

struct SelectorDecl {
    rate: u64,
    seen_at_ns: u64,
}

/// Domain rate implied by selectors, valid while `oldest_seen_at_ns` is still
/// inside the refresh window. `oldest_seen_at_ns` is `None` when no selector
/// is live, which does not expire.
#[derive(Default)]
struct SelectorConsensus {
    rate: Option<u64>,
    oldest_seen_at_ns: Option<u64>,
}

#[derive(PartialEq, Eq)]
enum Store {
    New,
    Changed,
    Same,
    Rejected,
}

impl SamplerRates {
    pub(super) fn remove_source(&mut self, source: &SourceId) {
        if let Some(entries) = self.entries.remove(source) {
            self.entry_count -= entries.len();
        }
        if let Some(options) = self.domain_rates.remove(source) {
            self.entry_count -= options.interfaces.len();
        }
    }

    fn remember_sampler(&mut self, source: &SourceId, sampler_id: u64, rate: u64) -> Store {
        if let Some(existing) = self
            .entries
            .get_mut(source)
            .and_then(|entries| entries.get_mut(&sampler_id))
        {
            if *existing == rate {
                return Store::Same;
            }
            *existing = rate;
            return Store::Changed;
        }
        if self.entry_count >= MAX_SAMPLER_RATE_ENTRIES {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
            return Store::Rejected;
        }
        self.entries
            .entry(source.clone())
            .or_default()
            .insert(sampler_id, rate);
        self.entry_count += 1;
        Store::New
    }

    fn remember_domain(&mut self, source: &SourceId, rate: u64) -> Store {
        if let Some(options) = self.domain_rates.get_mut(source) {
            return match options.domain {
                Some(current) if current == rate => Store::Same,
                Some(_) => {
                    options.domain = Some(rate);
                    Store::Changed
                }
                None => {
                    options.domain = Some(rate);
                    Store::New
                }
            };
        }
        if self.domain_rates.len() >= MAX_SAMPLER_RATE_ENTRIES {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
            return Store::Rejected;
        }
        self.domain_rates.insert(
            source.clone(),
            SourceOptions {
                domain: Some(rate),
                ..SourceOptions::default()
            },
        );
        Store::New
    }

    fn remember_interface(&mut self, source: &SourceId, interface: u32, rate: u64) -> Store {
        if let Some(options) = self.domain_rates.get_mut(source)
            && let Some(current) = options.interfaces.get_mut(&interface)
        {
            if *current == rate {
                return Store::Same;
            }
            *current = rate;
            return Store::Changed;
        }
        if !self.domain_rates.contains_key(source)
            && self.domain_rates.len() >= MAX_SAMPLER_RATE_ENTRIES
        {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
            return Store::Rejected;
        }
        if self.entry_count >= MAX_SAMPLER_RATE_ENTRIES {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
            return Store::Rejected;
        }
        self.domain_rates
            .entry(source.clone())
            .or_default()
            .interfaces
            .insert(interface, rate);
        self.entry_count += 1;
        Store::New
    }

    /// Records one selector declaration and refreshes the cached domain rate.
    ///
    /// Returns whether the declaration is stored. A new id past
    /// `MAX_SELECTORS_PER_SOURCE` is rejected; expired declarations are dropped
    /// first, so they do not hold a slot.
    fn note_selector(&mut self, source: &SourceId, id: u64, rate: u64, now_ns: u64) -> bool {
        if !self.domain_rates.contains_key(source)
            && self.domain_rates.len() >= MAX_SAMPLER_RATE_ENTRIES
        {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
            return false;
        }
        let accepted = {
            let options = self.domain_rates.entry(source.clone()).or_default();
            if !options.selectors.contains_key(&id)
                && options.selectors.len() >= MAX_SELECTORS_PER_SOURCE
            {
                rebuild_selector_consensus(options, now_ns);
            }
            let updated = if let Some(decl) = options.selectors.get_mut(&id) {
                decl.rate = rate;
                decl.seen_at_ns = now_ns;
                true
            } else {
                false
            };
            if updated || options.selectors.len() < MAX_SELECTORS_PER_SOURCE {
                if !updated {
                    options.selectors.insert(
                        id,
                        SelectorDecl {
                            rate,
                            seen_at_ns: now_ns,
                        },
                    );
                }
                rebuild_selector_consensus(options, now_ns);
                true
            } else {
                false
            }
        };
        if !accepted {
            self.rejected_inserts = self.rejected_inserts.saturating_add(1);
        }
        accepted
    }

    /// Records the rate one options data record declares, if it declares one.
    ///
    /// `interface` is set when the record's scope names an interface. A record
    /// that names a sampler or selector keeps that selector's rate instead.
    fn learn_options(
        &mut self,
        source: &SourceId,
        sampling: &SamplingFields,
        interface: Option<u32>,
        now_ns: u64,
    ) {
        let Some(rate) = sampling.rate() else {
            return;
        };
        let stored = if let Some(id) = sampling.sampler_id {
            let stored = self.remember_sampler(source, id, rate);
            if stored != Store::Rejected {
                self.note_selector(source, id, rate, now_ns);
            }
            stored
        } else if let Some(interface) = interface {
            self.remember_interface(source, interface, rate)
        } else {
            self.remember_domain(source, rate)
        };
        if matches!(stored, Store::New | Store::Changed) {
            self.options_rates_learned = self.options_rates_learned.saturating_add(1);
        }
    }

    /// The rate a flow record that declares none of its own inherits.
    ///
    /// Order: the sampler it names, the interface rate for `in_if` (or `out_if`
    /// when that input has no entry), the domain rate, then the cached selector
    /// agreement. That cache is rebuilt only when a selector is stored or its
    /// oldest contributor has left the refresh window.
    fn learned_rate(
        &mut self,
        source: &SourceId,
        sampler_id: Option<u64>,
        in_if: u32,
        out_if: u32,
        now_ns: u64,
    ) -> Option<u64> {
        if let Some(id) = sampler_id
            && let Some(rate) = self
                .entries
                .get(source)
                .and_then(|entries| entries.get(&id))
                .copied()
        {
            return Some(rate);
        }
        let options = self.domain_rates.get_mut(source)?;
        if let Some(rate) = options.interfaces.get(&in_if).copied() {
            return Some(rate);
        }
        if let Some(rate) = options.interfaces.get(&out_if).copied() {
            return Some(rate);
        }
        if let Some(rate) = options.domain {
            return Some(rate);
        }
        if sampler_id.is_some() {
            return None;
        }
        if !selector_consensus_fresh(&options.consensus, now_ns) {
            rebuild_selector_consensus(options, now_ns);
        }
        options.consensus.rate
    }
}

fn selector_consensus_fresh(consensus: &SelectorConsensus, now_ns: u64) -> bool {
    match consensus.oldest_seen_at_ns {
        Some(oldest) => {
            Duration::from_nanos(now_ns.saturating_sub(oldest)) < OPTIONS_REFRESH_WINDOW
        }
        None => true,
    }
}

fn rebuild_selector_consensus(options: &mut SourceOptions, now_ns: u64) {
    options.selectors.retain(|_, decl| {
        Duration::from_nanos(now_ns.saturating_sub(decl.seen_at_ns)) < OPTIONS_REFRESH_WINDOW
    });
    let mut rate = None;
    let mut oldest: Option<u64> = None;
    let mut conflict = false;
    for decl in options.selectors.values() {
        oldest = Some(match oldest {
            Some(seen) => seen.min(decl.seen_at_ns),
            None => decl.seen_at_ns,
        });
        if conflict {
            continue;
        }
        match rate {
            None => rate = Some(decl.rate),
            Some(current) if current == decl.rate => {}
            Some(_) => {
                rate = None;
                conflict = true;
            }
        }
    }
    options.consensus = SelectorConsensus {
        rate: if conflict { None } else { rate },
        oldest_seen_at_ns: oldest,
    };
}

fn ipfix_scope_interface(record: &[IPFixFieldPair]) -> Option<u32> {
    let mut egress = None;
    for (field, value) in record {
        let IPFixField::IANA(kind) = field else {
            continue;
        };
        let Some(index) = nonzero_u32(field_value_to_u32(value)) else {
            continue;
        };
        match kind {
            IANAIPFixField::IngressInterface => return Some(index),
            IANAIPFixField::EgressInterface if egress.is_none() => egress = Some(index),
            _ => {}
        }
    }
    egress
}

fn v9_scope_interface(scopes: &[ScopeDataField]) -> Option<u32> {
    scopes.iter().find_map(|scope| {
        let ScopeDataField::Interface(bytes) = scope else {
            return None;
        };
        interface_index(bytes)
    })
}

fn interface_index(bytes: &[u8]) -> Option<u32> {
    if bytes.is_empty() || bytes.len() > 4 {
        return None;
    }
    let mut index = 0u32;
    for byte in bytes {
        index = (index << 8) | u32::from(*byte);
    }
    nonzero_u32(index)
}

/// The sampling information elements of one flow or options record.
///
/// Exporters express a rate several ways (RFC 5477, RFC 7015): directly as
/// 1-in-N, as selected/skipped runs of packets or flows, as n out of a
/// population of N, or as a probability.
///
/// Only packet sampling makes a record's counters a sample.
///
/// Whole-flow selection keeps complete counters and publishes rate 1:
/// `flowSelectorAlgorithm`, `selectorAlgorithm` 9, a hash selector whose
/// `hashFlowDomain` is the flow key, and `samplingFlowInterval` /
/// `samplingFlowSpacing`. Hash selection without `hashFlowDomain` emulates
/// random packet sampling (RFC 5475 section 6.2) and uses the declared
/// ratio. Property match (`selectorAlgorithm` 5) is a filter. A filter or
/// hash selector that names no ratio declares no rate.
#[derive(Default)]
struct SamplingFields {
    sampler_id: Option<u64>,
    interval: Option<u64>,
    packet_interval: Option<u64>,
    packet_space: Option<u64>,
    flow_interval: Option<u64>,
    flow_spacing: Option<u64>,
    size: Option<u64>,
    population: Option<u64>,
    probability: Option<f64>,
    /// `selectorAlgorithm` 1-4, or `samplingAlgorithm` / `samplerMode` 1-2.
    packet_sampling: bool,
    /// `flowSelectorAlgorithm` (IE390), any value.
    flow_selector: bool,
    /// `selectorAlgorithm` 9, flow-state dependent intermediate flow selection.
    flow_state_selection: bool,
    /// `selectorAlgorithm` 5, property-match filtering.
    property_filter: bool,
    /// `selectorAlgorithm` 6-8, hash-based filtering.
    hash_selector: bool,
    /// Hash parameter elements other than `hashFlowDomain` (IE327-334).
    hash_parameters: bool,
    /// `hashFlowDomain` (IE400): the hash input is the flow key.
    hash_flow_domain: bool,
}

impl SamplingFields {
    /// Takes the field if it is a sampling element; reports whether it was.
    fn observe_ipfix(&mut self, field: &IPFixField, value: &FieldValue) -> bool {
        let IPFixField::IANA(field) = field else {
            return false;
        };
        let slot = match field {
            IANAIPFixField::SamplerId | IANAIPFixField::SelectorId => &mut self.sampler_id,
            IANAIPFixField::SamplingInterval | IANAIPFixField::SamplerRandomInterval => {
                &mut self.interval
            }
            IANAIPFixField::SamplingPacketInterval => &mut self.packet_interval,
            IANAIPFixField::SamplingPacketSpace => &mut self.packet_space,
            IANAIPFixField::SamplingFlowInterval => &mut self.flow_interval,
            IANAIPFixField::SamplingFlowSpacing => &mut self.flow_spacing,
            IANAIPFixField::SamplingSize => &mut self.size,
            IANAIPFixField::SamplingPopulation => &mut self.population,
            IANAIPFixField::SamplingProbability => {
                self.probability = Some(field_value_to_f64(value));
                return true;
            }
            IANAIPFixField::SelectorAlgorithm => {
                // RFC 5477 registry: 1-4 sample packets; 5 is property-match
                // filtering, 6-8 hash-based filtering, 9 flow-state selection.
                match field_value_to_u64(value) {
                    1..=4 => self.packet_sampling = true,
                    5 => self.property_filter = true,
                    6..=8 => self.hash_selector = true,
                    9 => self.flow_state_selection = true,
                    _ => {}
                }
                return true;
            }
            IANAIPFixField::SamplingAlgorithm | IANAIPFixField::SamplerMode => {
                // 1 deterministic, 2 random: both sample packets.
                if matches!(field_value_to_u64(value), 1 | 2) {
                    self.packet_sampling = true;
                }
                return true;
            }
            IANAIPFixField::FlowSelectorAlgorithm => {
                self.flow_selector = true;
                return true;
            }
            IANAIPFixField::HashFlowDomain => {
                self.hash_flow_domain = true;
                return true;
            }
            IANAIPFixField::HashIppayloadOffset
            | IANAIPFixField::HashIppayloadSize
            | IANAIPFixField::HashOutputRangeMin
            | IANAIPFixField::HashOutputRangeMax
            | IANAIPFixField::HashSelectedRangeMin
            | IANAIPFixField::HashSelectedRangeMax
            | IANAIPFixField::HashDigestOutput
            | IANAIPFixField::HashInitialiserValue => {
                self.hash_parameters = true;
                return true;
            }
            _ => return false,
        };
        *slot = nonzero_u64(field_value_to_u64(value));
        true
    }

    /// Takes the field if it is a sampling element; reports whether it was.
    fn observe_v9(&mut self, field: &V9Field, value: &FieldValue) -> bool {
        let slot = match field {
            V9Field::FlowSamplerId => &mut self.sampler_id,
            V9Field::SamplingInterval | V9Field::FlowSamplerRandomInterval => &mut self.interval,
            _ => return false,
        };
        *slot = nonzero_u64(field_value_to_u64(value));
        true
    }

    /// The 1-in-N rate these fields declare, if they declare one.
    ///
    /// Whole-flow selection publishes 1, which replaces a packet rate learned
    /// earlier for the same scope. A property-match filter publishes nothing.
    /// A hash selector with no ratio publishes nothing, so it does not vote
    /// in a selection sequence.
    ///
    /// A lone packet interval is read as 1-in-N, as exporters that send it
    /// without a spacing use it; with a spacing it is the RFC run length, and
    /// the rate is (selected + skipped) / selected.
    fn rate(&self) -> Option<u64> {
        if self.whole_flow() {
            return Some(1);
        }
        // A property-match filter is not a sampler. A hash selector that
        // names no ratio is not one either. Packet-content hashing that
        // does declare a ratio falls through to that ratio.
        if !self.packet_sampling
            && (self.property_filter || (self.hash_selection() && !self.declares_ratio()))
        {
            return None;
        }
        self.packet_rate()
    }

    /// Selection that exports complete per-flow counters.
    ///
    /// An explicit packet-sampling algorithm on the same record keeps the
    /// packet derivation. Flow-key hashing counts only when a ratio is
    /// present; a bare hash selector declares no rate.
    fn whole_flow(&self) -> bool {
        if self.packet_sampling {
            return false;
        }
        let flow_level = self.flow_interval.is_some() || self.flow_spacing.is_some();
        self.flow_selector
            || self.flow_state_selection
            || flow_level
            || (self.hash_selection() && self.hash_flow_domain && self.declares_ratio())
    }

    /// Hash-based filtering (`selectorAlgorithm` 6-8) or a hash parameter.
    fn hash_selection(&self) -> bool {
        self.hash_selector || self.hash_parameters || self.hash_flow_domain
    }

    /// A sampling interval, size, population, probability, packet run, or
    /// flow interval. Naming a selector algorithm is not a ratio.
    fn declares_ratio(&self) -> bool {
        self.interval.is_some()
            || self.packet_interval.is_some()
            || self.packet_space.is_some()
            || self.flow_interval.is_some()
            || self.flow_spacing.is_some()
            || self.size.is_some()
            || self.population.is_some()
            || self.probability.is_some()
    }

    fn packet_rate(&self) -> Option<u64> {
        let packet_interval = match (self.packet_interval, self.packet_space) {
            (Some(selected), Some(skipped)) => {
                rounded_ratio(u128::from(selected) + u128::from(skipped), selected)
            }
            (selected, _) => selected,
        };
        self.interval
            .or_else(|| rounded_ratio(u128::from(self.population?), self.size?))
            .or(packet_interval)
            .or_else(|| sampling_rate_from_probability(self.probability?))
    }
}

/// `numerator / denominator` rounded to the nearest integer, saturating.
fn rounded_ratio(numerator: u128, denominator: u64) -> Option<u64> {
    let denominator = u128::from(denominator);
    let rounded = (numerator + denominator / 2) / denominator;
    nonzero_u64(u64::try_from(rounded).unwrap_or(u64::MAX))
}

pub struct Converter {
    pub packet: NetflowPacket,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
    fallback_sampling_rate: u64,
    max_sampling_rate: u64,
}

impl Converter {
    pub fn new(
        packet: NetflowPacket,
        sampler_addr: SocketAddr,
        receive_time_ns: u64,
        fallback_sampling_rate: u64,
        max_sampling_rate: u64,
    ) -> Self {
        Self {
            packet,
            sampler_addr,
            receive_time_ns,
            fallback_sampling_rate: fallback_sampling_rate.max(1),
            max_sampling_rate: max_sampling_rate.max(1),
        }
    }

    pub fn convert_with_sampler_rates(
        &self,
        sampler_rates: &mut SamplerRates,
    ) -> Vec<flowpb::FlowMessage> {
        match &self.packet {
            NetflowPacket::V5(v5) => self.convert_v5(v5, sampler_rates),
            NetflowPacket::V9(v9) => self.convert_v9(v9, sampler_rates),
            NetflowPacket::IPFix(ipfix) => self.convert_ipfix(ipfix, sampler_rates),
            _ => {
                debug!("Unsupported NetFlow version: {:?}", self.packet);
                Vec::new()
            }
        }
    }

    pub fn convert_v5(
        &self,
        packet: &V5,
        sampler_rates: &mut SamplerRates,
    ) -> Vec<flowpb::FlowMessage> {
        let mut messages = Vec::with_capacity(packet.flowsets.len());
        // v5 masks its interval to 14 bits, so the wire value tops out at
        // 16,383 -- but any ceiling below that is reachable from the packet
        // itself, not just from a misconfigured fallback, so the clamp has to
        // be counted like every other.
        let (sampling_rate, was_clamped) = bound_sampling_rate(
            v5_sampling_interval_to_rate(packet.header.sampling_interval)
                .unwrap_or(self.fallback_sampling_rate),
            self.max_sampling_rate,
        );
        if was_clamped {
            sampler_rates.clamped_rates = sampler_rates.clamped_rates.saturating_add(1);
        }

        for flow in &packet.flowsets {
            let mut msg = flowpb::FlowMessage {
                r#type: i32::from(flowpb::flow_message::FlowType::NetflowV5),
                time_received_ns: self.receive_time_ns,
                sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                sequence_num: packet.header.flow_sequence,
                sampling_rate,
                ..Default::default()
            };

            msg.src_addr = flow.src_addr.octets().to_vec();
            msg.dst_addr = flow.dst_addr.octets().to_vec();
            msg.src_port = u32::from(flow.src_port);
            msg.dst_port = u32::from(flow.dst_port);
            msg.proto = u32::from(flow.protocol_number);
            msg.protocol_name = protocol_type_name(ProtocolTypes::from(flow.protocol_number));
            msg.bytes = u64::from(flow.d_octets);
            msg.packets = u64::from(flow.d_pkts);
            msg.bytes_out = msg.bytes;
            msg.packets_out = msg.packets;

            let uptime_ms = packet.header.sys_up_time;
            let unix_secs = packet.header.unix_secs;
            let unix_nsecs = packet.header.unix_nsecs;

            let base_time_ns = (u64::from(unix_secs))
                .checked_mul(1_000_000_000)
                .and_then(|secs_ns| secs_ns.checked_add(u64::from(unix_nsecs)))
                .unwrap_or(0);
            msg.time_flow_start_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.first);
            msg.time_flow_end_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.last);

            msg.in_if = u32::from(flow.input);
            msg.out_if = u32::from(flow.output);
            msg.next_hop = flow.next_hop.octets().to_vec();
            msg.src_as = u32::from(flow.src_as);
            msg.dst_as = u32::from(flow.dst_as);
            msg.tcp_flags = u32::from(flow.tcp_flags);
            msg.ip_tos = u32::from(flow.tos);
            msg.src_net = u32::from(flow.src_mask);
            msg.dst_net = u32::from(flow.dst_mask);

            messages.push(msg);
        }

        messages
    }

    pub fn convert_v9(
        &self,
        packet: &netflow_parser::variable_versions::v9::V9,
        sampler_rates: &mut SamplerRates,
    ) -> Vec<flowpb::FlowMessage> {
        use netflow_parser::variable_versions::v9::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            match &flowset.body {
                FlowSetBody::Data(data) => {
                    for fields in &data.fields {
                        let mut msg = flowpb::FlowMessage {
                            r#type: i32::from(flowpb::flow_message::FlowType::NetflowV9),
                            time_received_ns: self.receive_time_ns,
                            sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                            sequence_num: packet.header.sequence_number,
                            ..Default::default()
                        };
                        let mut sampling = SamplingFields::default();

                        for (field_type, field_value) in fields {
                            if sampling.observe_v9(field_type, field_value) {
                                continue;
                            }
                            match field_type {
                                V9Field::Ipv4SrcAddr => {
                                    if msg.src_addr.is_empty() {
                                        msg.src_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::Ipv6SrcAddr => {
                                    if msg.src_addr.is_empty() {
                                        msg.src_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::Ipv4DstAddr => {
                                    if msg.dst_addr.is_empty() {
                                        msg.dst_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::Ipv6DstAddr => {
                                    if msg.dst_addr.is_empty() {
                                        msg.dst_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::L4SrcPort => {
                                    msg.src_port = field_value_to_u32(field_value)
                                }
                                V9Field::L4DstPort => {
                                    msg.dst_port = field_value_to_u32(field_value)
                                }
                                V9Field::Protocol => {
                                    msg.proto = field_value_to_u32(field_value);
                                    msg.protocol_name = field_value_to_protocol_name(field_value);
                                }
                                V9Field::InBytes => msg.bytes = field_value_to_u64(field_value),
                                V9Field::InPkts => msg.packets = field_value_to_u64(field_value),
                                V9Field::FirstSwitched => {
                                    let flow_uptime = field_value_to_u32(field_value);
                                    let uptime_ms = packet.header.sys_up_time;
                                    let unix_secs = packet.header.unix_secs;
                                    let base_time_ns = (u64::from(unix_secs))
                                        .checked_mul(1_000_000_000)
                                        .unwrap_or(0);
                                    msg.time_flow_start_ns =
                                        calculate_flow_time(base_time_ns, uptime_ms, flow_uptime);
                                }
                                V9Field::LastSwitched => {
                                    let flow_uptime = field_value_to_u32(field_value);
                                    let uptime_ms = packet.header.sys_up_time;
                                    let unix_secs = packet.header.unix_secs;
                                    let base_time_ns = (u64::from(unix_secs))
                                        .checked_mul(1_000_000_000)
                                        .unwrap_or(0);
                                    msg.time_flow_end_ns =
                                        calculate_flow_time(base_time_ns, uptime_ms, flow_uptime);
                                }
                                V9Field::InputSnmp => msg.in_if = field_value_to_u32(field_value),
                                V9Field::OutputSnmp => msg.out_if = field_value_to_u32(field_value),
                                V9Field::InSrcMac => {
                                    msg.src_mac = field_value_to_mac_u64(field_value)
                                }
                                V9Field::InDstMac | V9Field::OutDstMac => {
                                    if msg.dst_mac == 0 {
                                        msg.dst_mac = field_value_to_mac_u64(field_value);
                                    }
                                }
                                V9Field::SrcAs => msg.src_as = field_value_to_u32(field_value),
                                V9Field::DstAs => msg.dst_as = field_value_to_u32(field_value),
                                V9Field::Ipv4NextHop => {
                                    if msg.next_hop.is_empty() {
                                        msg.next_hop = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::Ipv6NextHop => {
                                    if msg.next_hop.is_empty() {
                                        msg.next_hop = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                V9Field::SrcMask => msg.src_net = field_value_to_u32(field_value),
                                V9Field::DstMask => msg.dst_net = field_value_to_u32(field_value),
                                V9Field::Ipv6SrcMask => {
                                    if msg.src_net == 0 {
                                        msg.src_net = field_value_to_u32(field_value);
                                    }
                                }
                                V9Field::Ipv6DstMask => {
                                    if msg.dst_net == 0 {
                                        msg.dst_net = field_value_to_u32(field_value);
                                    }
                                }
                                V9Field::TcpFlags => {
                                    msg.tcp_flags = field_value_to_u32(field_value)
                                }
                                V9Field::SrcTos => msg.ip_tos = field_value_to_u32(field_value),
                                V9Field::SrcVlan => msg.src_vlan = field_value_to_u32(field_value),
                                V9Field::DstVlan => msg.dst_vlan = field_value_to_u32(field_value),
                                V9Field::Ipv6FlowLabel => {
                                    msg.ipv6_flow_label = field_value_to_u32(field_value)
                                }
                                V9Field::IcmpType => {
                                    let val = field_value_to_u32(field_value);
                                    msg.icmp_type = (val >> 8) & 0xFF;
                                    msg.icmp_code = val & 0xFF;
                                }
                                _ => {}
                            }
                        }

                        msg.bytes_out = msg.bytes;
                        msg.packets_out = msg.packets;
                        self.apply_sampling_rate(&mut msg, &sampling, sampler_rates);

                        messages.push(msg);
                    }
                }
                FlowSetBody::OptionsData(options) => {
                    let source = self.source();
                    let now_ns = self.receive_time_ns;
                    for record in &options.fields {
                        let mut sampling = SamplingFields::default();
                        for (field, value) in &record.options_fields {
                            sampling.observe_v9(field, value);
                        }
                        sampler_rates.learn_options(
                            &source,
                            &sampling,
                            v9_scope_interface(&record.scope_fields),
                            now_ns,
                        );
                    }
                }
                FlowSetBody::NoTemplate(info) => {
                    debug!(
                        "V9 flowset skipped - no template for ID {} ({} bytes raw data)",
                        info.template_id,
                        info.raw_data.len()
                    );
                }
                _ => {}
            }
        }

        messages
    }

    pub fn convert_ipfix(
        &self,
        packet: &netflow_parser::variable_versions::ipfix::IPFix,
        sampler_rates: &mut SamplerRates,
    ) -> Vec<flowpb::FlowMessage> {
        use netflow_parser::variable_versions::ipfix::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            match &flowset.body {
                FlowSetBody::Data(data) => {
                    for fields in &data.fields {
                        let mut msg = flowpb::FlowMessage {
                            r#type: i32::from(flowpb::flow_message::FlowType::Ipfix),
                            time_received_ns: self.receive_time_ns,
                            sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                            sequence_num: packet.header.sequence_number,
                            observation_domain_id: packet.header.observation_domain_id,
                            ..Default::default()
                        };
                        let mut sampling = SamplingFields::default();

                        for (field_type, field_value) in fields {
                            if sampling.observe_ipfix(field_type, field_value) {
                                continue;
                            }
                            match field_type {
                                IPFixField::IANA(IANAIPFixField::SourceIpv4address) => {
                                    if msg.src_addr.is_empty() {
                                        msg.src_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::SourceIpv6address) => {
                                    if msg.src_addr.is_empty() {
                                        msg.src_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationIpv4address) => {
                                    if msg.dst_addr.is_empty() {
                                        msg.dst_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationIpv6address) => {
                                    if msg.dst_addr.is_empty() {
                                        msg.dst_addr = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::SourceTransportPort) => {
                                    msg.src_port = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationTransportPort) => {
                                    msg.dst_port = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::ProtocolIdentifier) => {
                                    msg.proto = field_value_to_u32(field_value);
                                    msg.protocol_name = field_value_to_protocol_name(field_value);
                                }
                                IPFixField::IANA(IANAIPFixField::OctetDeltaCount) => {
                                    let value = field_value_to_u64(field_value);
                                    msg.bytes = value;
                                    msg.bytes_out = value;
                                }
                                IPFixField::IANA(IANAIPFixField::OctetTotalCount) => {
                                    if msg.bytes_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.bytes = value;
                                        msg.bytes_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::PacketDeltaCount) => {
                                    let value = field_value_to_u64(field_value);
                                    msg.packets = value;
                                    msg.packets_out = value;
                                }
                                IPFixField::IANA(IANAIPFixField::PacketTotalCount) => {
                                    if msg.packets_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.packets = value;
                                        msg.packets_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::InitiatorOctets) => {
                                    if msg.bytes_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.bytes = value;
                                        msg.bytes_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::ResponderOctets) => {
                                    if msg.bytes_in == 0 {
                                        msg.bytes_in = field_value_to_u64(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::InitiatorPackets) => {
                                    if msg.packets_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.packets = value;
                                        msg.packets_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::ResponderPackets) => {
                                    if msg.packets_in == 0 {
                                        msg.packets_in = field_value_to_u64(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::FlowStartMilliseconds) => {
                                    msg.time_flow_start_ns = field_value_to_u64(field_value)
                                        .checked_mul(1_000_000)
                                        .unwrap_or(0);
                                }
                                IPFixField::IANA(IANAIPFixField::FlowStartSysUpTime) => {
                                    if msg.time_flow_start_ns == 0 {
                                        let flow_uptime = field_value_to_u32(field_value);
                                        let export_time = packet.header.export_time;
                                        let base_time_ns = (u64::from(export_time))
                                            .checked_mul(1_000_000_000)
                                            .unwrap_or(0);
                                        msg.time_flow_start_ns = base_time_ns.saturating_sub(
                                            (u64::from(flow_uptime)).saturating_mul(1_000_000),
                                        );
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::FlowEndMilliseconds) => {
                                    msg.time_flow_end_ns = field_value_to_u64(field_value)
                                        .checked_mul(1_000_000)
                                        .unwrap_or(0);
                                }
                                IPFixField::IANA(IANAIPFixField::FlowEndSysUpTime) => {
                                    if msg.time_flow_end_ns == 0 {
                                        let flow_uptime = field_value_to_u32(field_value);
                                        let export_time = packet.header.export_time;
                                        let base_time_ns = (u64::from(export_time))
                                            .checked_mul(1_000_000_000)
                                            .unwrap_or(0);
                                        msg.time_flow_end_ns = base_time_ns.saturating_sub(
                                            (u64::from(flow_uptime)).saturating_mul(1_000_000),
                                        );
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::IngressInterface) => {
                                    msg.in_if = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::EgressInterface) => {
                                    msg.out_if = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::SourceMacaddress) => {
                                    msg.src_mac = field_value_to_mac_u64(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationMacaddress) => {
                                    msg.dst_mac = field_value_to_mac_u64(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpSourceAsNumber) => {
                                    msg.src_as = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpDestinationAsNumber) => {
                                    msg.dst_as = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpNextAdjacentAsNumber) => {
                                    msg.next_hop_as = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::IpNextHopIpv4address) => {
                                    if msg.next_hop.is_empty() {
                                        msg.next_hop = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::IpNextHopIpv6address) => {
                                    if msg.next_hop.is_empty() {
                                        msg.next_hop = field_value_to_ip_bytes(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::BgpNextHopIpv4address) => {
                                    msg.bgp_next_hop = field_value_to_ip_bytes(field_value);
                                }
                                IPFixField::IANA(IANAIPFixField::BgpNextHopIpv6address) => {
                                    if msg.bgp_next_hop.is_empty() {
                                        msg.bgp_next_hop = field_value_to_ip_bytes(field_value);
                                    }
                                }

                                // BGP Communities
                                IPFixField::IANA(IANAIPFixField::BgpCommunity) => {
                                    let communities = parse_bgp_communities(field_value);
                                    msg.bgp_communities.extend(communities);
                                }
                                IPFixField::IANA(IANAIPFixField::BgpSourceCommunityList) => {
                                    let communities = parse_bgp_communities(field_value);
                                    msg.bgp_communities.extend(communities);
                                }
                                IPFixField::IANA(IANAIPFixField::BgpDestinationCommunityList) => {
                                    let communities = parse_bgp_communities(field_value);
                                    msg.bgp_communities.extend(communities);
                                }

                                // Network masks / prefix lengths
                                IPFixField::IANA(IANAIPFixField::SourceIpv4prefixLength) => {
                                    msg.src_net = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationIpv4prefixLength) => {
                                    msg.dst_net = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::SourceIpv6prefixLength) => {
                                    if msg.src_net == 0 {
                                        msg.src_net = field_value_to_u32(field_value)
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationIpv6prefixLength) => {
                                    if msg.dst_net == 0 {
                                        msg.dst_net = field_value_to_u32(field_value)
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::TcpControlBits) => {
                                    msg.tcp_flags = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::IpClassOfService) => {
                                    msg.ip_tos = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::MinimumTtl) => {
                                    msg.ip_ttl = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::MaximumTtl) => {
                                    if msg.ip_ttl == 0 {
                                        msg.ip_ttl = field_value_to_u32(field_value)
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::VlanId) => {
                                    msg.vlan_id = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::Dot1qVlanId) => {
                                    msg.src_vlan = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::PostDot1qVlanId) => {
                                    msg.dst_vlan = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::FlowLabelIpv6) => {
                                    msg.ipv6_flow_label = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::IcmpTypeCodeIpv4) => {
                                    let val = field_value_to_u32(field_value);
                                    msg.icmp_type = (val >> 8) & 0xFF;
                                    msg.icmp_code = val & 0xFF;
                                }
                                IPFixField::IANA(IANAIPFixField::IcmpTypeCodeIpv6) => {
                                    if msg.icmp_type == 0 && msg.icmp_code == 0 {
                                        let val = field_value_to_u32(field_value);
                                        msg.icmp_type = (val >> 8) & 0xFF;
                                        msg.icmp_code = val & 0xFF;
                                    }
                                }
                                IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReverseOctetDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReverseOctetTotalCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostOctetDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostOctetTotalCount,
                                ) => {
                                    if msg.bytes_in == 0 {
                                        msg.bytes_in = field_value_to_u64(field_value);
                                    }
                                }
                                IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePacketDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePacketTotalCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostPacketDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostPacketTotalCount,
                                ) => {
                                    if msg.packets_in == 0 {
                                        msg.packets_in = field_value_to_u64(field_value);
                                    }
                                }
                                _ => {
                                    debug!("Unhandled IPFIX field: {:?}", field_type);
                                }
                            }
                        }

                        // Construct AS path from available BGP AS fields
                        msg.as_path = construct_as_path(msg.src_as, msg.dst_as, msg.next_hop_as);
                        self.apply_sampling_rate(&mut msg, &sampling, sampler_rates);

                        messages.push(msg);
                    }
                }
                FlowSetBody::OptionsData(options) => {
                    let source = self.source();
                    let now_ns = self.receive_time_ns;
                    for record in &options.fields {
                        let mut sampling = SamplingFields::default();
                        for (field, value) in record {
                            sampling.observe_ipfix(field, value);
                        }
                        sampler_rates.learn_options(
                            &source,
                            &sampling,
                            ipfix_scope_interface(record),
                            now_ns,
                        );
                    }
                }
                FlowSetBody::NoTemplate(info) => {
                    debug!(
                        "IPFIX flowset skipped - no template for ID {} ({} bytes raw data)",
                        info.template_id,
                        info.raw_data.len()
                    );
                }
                _ => {}
            }
        }

        messages
    }

    fn source(&self) -> SourceId {
        match &self.packet {
            NetflowPacket::IPFix(packet) => SourceId::Ipfix(IpfixSourceKey {
                addr: self.sampler_addr,
                observation_domain_id: packet.header.observation_domain_id,
            }),
            NetflowPacket::V9(packet) => SourceId::V9(V9SourceKey {
                addr: self.sampler_addr,
                source_id: packet.header.source_id,
            }),
            _ => SourceId::Legacy(self.sampler_addr),
        }
    }

    /// Resolves a flow's rate: the record's own sampling fields, then the rate
    /// learned for the sampler it names, then the interface rate, then the
    /// domain rate, then the configured per-exporter override or default.
    fn apply_sampling_rate(
        &self,
        msg: &mut flowpb::FlowMessage,
        sampling: &SamplingFields,
        sampler_rates: &mut SamplerRates,
    ) {
        let source = self.source();
        let record_sampling_rate = sampling.rate();

        if let (Some(id), Some(rate)) = (sampling.sampler_id, record_sampling_rate) {
            sampler_rates.remember_sampler(&source, id, rate);
        }

        let resolved = record_sampling_rate
            .or_else(|| {
                sampler_rates.learned_rate(
                    &source,
                    sampling.sampler_id,
                    msg.in_if,
                    msg.out_if,
                    self.receive_time_ns,
                )
            })
            .unwrap_or(self.fallback_sampling_rate);

        let (bounded, was_clamped) = bound_sampling_rate(resolved, self.max_sampling_rate);
        if was_clamped {
            sampler_rates.clamped_rates = sampler_rates.clamped_rates.saturating_add(1);
        }
        msg.sampling_rate = bounded;
    }
}

// Helper functions

fn ip_to_bytes(ip: &IpAddr) -> Vec<u8> {
    match ip {
        IpAddr::V4(addr) => addr.octets().to_vec(),
        IpAddr::V6(addr) => addr.octets().to_vec(),
    }
}

fn mac_to_u64(mac: &[u8]) -> u64 {
    let mut result = 0u64;
    for (i, &byte) in mac.iter().take(6).enumerate() {
        result |= (u64::from(byte)) << (40 - i * 8);
    }
    result
}

fn calculate_flow_time(base_time_ns: u64, sys_uptime_ms: u32, flow_uptime_ms: u32) -> u64 {
    if sys_uptime_ms >= flow_uptime_ms {
        let offset_ms = u64::from(sys_uptime_ms.saturating_sub(flow_uptime_ms));
        base_time_ns.saturating_sub(offset_ms.saturating_mul(1_000_000))
    } else {
        base_time_ns
    }
}

/// Applies the sampling-rate floor and ceiling, reporting whether the ceiling
/// bound the value.
///
/// The floor keeps a zero or missing rate from erasing a flow's volume. The
/// ceiling keeps an absurd exporter-declared rate from fabricating volume:
/// downstream analytics multiply byte and packet counts by this number, and
/// every IPFIX/v9 sampling field is unauthenticated wire input that decodes to
/// a full `u64`.
pub(crate) fn bound_sampling_rate(resolved: u64, max_sampling_rate: u64) -> (u64, bool) {
    let ceiling = max_sampling_rate.max(1);
    let floored = resolved.max(1);
    if floored > ceiling {
        (ceiling, true)
    } else {
        (floored, false)
    }
}

fn v5_sampling_interval_to_rate(raw: u16) -> Option<u64> {
    // RFC 3954 stores mode in the top two bits and interval in the lower 14.
    let interval = raw & 0x3fff;
    nonzero_u64(u64::from(interval))
}

fn nonzero_u64(value: u64) -> Option<u64> {
    if value > 0 { Some(value) } else { None }
}

fn nonzero_u32(value: u32) -> Option<u32> {
    if value > 0 { Some(value) } else { None }
}

fn field_value_to_ip_bytes(value: &FieldValue) -> Vec<u8> {
    match value {
        FieldValue::Ip4Addr(addr) => addr.octets().to_vec(),
        FieldValue::Ip6Addr(addr) => addr.octets().to_vec(),
        _ => vec![],
    }
}

fn data_number_to_u32(dn: &DataNumber) -> u32 {
    match *dn {
        DataNumber::U8(v) => u32::from(v),
        DataNumber::I8(v) => v.max(0) as u32,
        DataNumber::U16(v) => u32::from(v),
        DataNumber::I16(v) => v.max(0) as u32,
        DataNumber::U24(v) => v,
        DataNumber::I24(v) => v.max(0) as u32,
        DataNumber::U32(v) => v,
        DataNumber::I32(v) => v.max(0) as u32,
        DataNumber::U64(v) => v.min(u64::from(u32::MAX)) as u32,
        DataNumber::I64(v) => v.max(0).min(i64::from(u32::MAX)) as u32,
        DataNumber::U128(v) => v.min(u128::from(u32::MAX)) as u32,
        DataNumber::I128(v) => v.max(0).min(i128::from(u32::MAX)) as u32,
        _ => 0,
    }
}

fn data_number_to_u64(dn: &DataNumber) -> u64 {
    match *dn {
        DataNumber::U8(v) => u64::from(v),
        DataNumber::I8(v) => v.max(0) as u64,
        DataNumber::U16(v) => u64::from(v),
        DataNumber::I16(v) => v.max(0) as u64,
        DataNumber::U24(v) => u64::from(v),
        DataNumber::I24(v) => v.max(0) as u64,
        DataNumber::U32(v) => u64::from(v),
        DataNumber::I32(v) => v.max(0) as u64,
        DataNumber::U64(v) => v,
        DataNumber::I64(v) => v.max(0) as u64,
        DataNumber::U128(v) => v.min(u128::from(u64::MAX)) as u64,
        DataNumber::I128(v) => v.max(0).min(i128::from(u64::MAX)) as u64,
        _ => 0,
    }
}

fn field_value_to_u32(value: &FieldValue) -> u32 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u32(dn),
        FieldValue::Duration(d) => u32::try_from(d.as_duration().as_millis()).unwrap_or(u32::MAX),
        FieldValue::ProtocolType(pt) => u32::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(f64::from(u32::MAX)) as u32,
        _ => 0,
    }
}

fn field_value_to_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u64(dn),
        FieldValue::Duration(d) => d.as_duration().as_millis().try_into().unwrap_or(u64::MAX),
        FieldValue::ProtocolType(pt) => u64::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(u64::MAX as f64) as u64,
        _ => 0,
    }
}

fn field_value_to_f64(value: &FieldValue) -> f64 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u64(dn) as f64,
        FieldValue::Float64(f) => *f,
        _ => 0.0,
    }
}

fn sampling_rate_from_probability(probability: f64) -> Option<u64> {
    if probability.is_finite() && probability > 0.0 && probability <= 1.0 {
        Some((1.0 / probability).round().max(1.0) as u64)
    } else {
        None
    }
}

fn field_value_to_mac_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::MacAddr(bytes) => mac_to_u64(bytes),
        _ => 0,
    }
}

fn protocol_type_name(pt: ProtocolTypes) -> String {
    format!("{pt:?}").to_uppercase()
}

fn field_value_to_protocol_name(value: &FieldValue) -> String {
    match value {
        FieldValue::ProtocolType(pt) => protocol_type_name(*pt),
        FieldValue::DataNumber(dn) => {
            let n = data_number_to_u32(dn) as u8;
            protocol_type_name(ProtocolTypes::from(n))
        }
        _ => String::new(),
    }
}

/// Construct AS path from available BGP AS fields.
/// Creates a partial path using source AS, adjacent AS, and destination AS.
/// Returns empty vec if no AS information is available.
/// Limits to 50 ASNs maximum per spec requirement.
fn construct_as_path(src_as: u32, dst_as: u32, next_hop_as: u32) -> Vec<u32> {
    let mut path = Vec::new();

    // Add source AS if non-zero
    if src_as > 0 {
        path.push(src_as);
    }

    // Add next-hop AS if non-zero and different from source/dest
    if next_hop_as > 0 && next_hop_as != src_as && next_hop_as != dst_as {
        path.push(next_hop_as);
    }

    // Add destination AS if non-zero and different from source
    if dst_as > 0 && dst_as != src_as {
        path.push(dst_as);
    }

    // Truncate to 50 ASNs if somehow exceeded (shouldn't happen with this logic)
    if path.len() > 50 {
        path.truncate(50);
    }

    path
}

/// Parse BGP communities from IPFIX field value.
/// Handles both individual community values (u32) and community lists (strings).
/// Returns vec of 32-bit community values in standard format.
fn parse_bgp_communities(value: &FieldValue) -> Vec<u32> {
    match value {
        // Single community as unsigned number
        FieldValue::DataNumber(dn) => {
            let community = data_number_to_u32(dn);
            if community > 0 {
                vec![community]
            } else {
                vec![]
            }
        }
        // Community list as string (format: "65000:100,65000:200")
        FieldValue::String(s) => {
            s.value
                .split(',')
                .filter_map(|community_str| {
                    let parts: Vec<&str> = community_str.trim().split(':').collect();
                    if parts.len() == 2 {
                        // Parse AS:value format into 32-bit community
                        let as_num: u32 = parts[0].parse().ok()?;
                        let value: u32 = parts[1].parse().ok()?;
                        // High 16 bits = AS, low 16 bits = value
                        Some((as_num << 16) | (value & 0xFFFF))
                    } else {
                        // Try parsing as raw 32-bit number
                        community_str.trim().parse().ok()
                    }
                })
                .collect()
        }
        // Vec of bytes - could be encoded communities
        FieldValue::Vec(bytes) => {
            // Each community is 4 bytes (32-bit value)
            bytes
                .as_chunks::<4>()
                .0
                .iter()
                .map(|chunk| u32::from_be_bytes(*chunk))
                .collect()
        }
        _ => vec![],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use netflow_parser::protocol::ProtocolTypes;
    use netflow_parser::variable_versions::field_value::{DurationValue, StringValue};
    use netflow_parser::variable_versions::ipfix::FlowSetBody;

    fn make_string_value(s: &str) -> StringValue {
        StringValue {
            value: s.to_string(),
            raw: s.as_bytes().to_vec(),
        }
    }

    #[test]
    fn test_mac_to_u64() {
        let mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let result = mac_to_u64(&mac);
        assert_eq!(result, 0x001122334455);
    }

    #[test]
    fn test_calculate_flow_time() {
        let base = 1_000_000_000_000;
        let sys_uptime = 10000;
        let flow_uptime = 5000;
        let result = calculate_flow_time(base, sys_uptime, flow_uptime);
        assert_eq!(result, base - 5_000_000_000);
    }

    #[test]
    fn test_ip_to_bytes_v4() {
        let ip = IpAddr::V4([192, 168, 1, 1].into());
        let bytes = ip_to_bytes(&ip);
        assert_eq!(bytes, vec![192, 168, 1, 1]);
    }

    #[test]
    fn test_data_number_to_u32_unsigned() {
        assert_eq!(data_number_to_u32(&DataNumber::U8(255)), 255);
        assert_eq!(data_number_to_u32(&DataNumber::U16(65535)), 65535);
        assert_eq!(data_number_to_u32(&DataNumber::U32(42)), 42);
    }

    #[test]
    fn test_data_number_to_u32_saturates_large() {
        assert_eq!(
            data_number_to_u32(&DataNumber::U64(u64::from(u32::MAX) + 1)),
            u32::MAX
        );
    }

    #[test]
    fn test_data_number_to_u32_signed_negative() {
        assert_eq!(data_number_to_u32(&DataNumber::I8(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I32(-1)), 0);
    }

    #[test]
    fn test_field_value_to_u32_protocol_type() {
        let fv = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        assert_eq!(field_value_to_u32(&fv), 6);
    }

    #[test]
    fn test_field_value_to_u32_duration() {
        let fv = FieldValue::Duration(DurationValue::Millis {
            value: 28_796_274,
            width: 4,
        });
        assert_eq!(field_value_to_u32(&fv), 28_796_274);
    }

    #[test]
    fn test_field_value_to_u64_data_number() {
        let fv = FieldValue::DataNumber(DataNumber::U32(35000));
        assert_eq!(field_value_to_u64(&fv), 35000);
    }

    #[test]
    fn test_v5_sampling_interval_strips_mode_bits() {
        let raw = 0b1000_0000_0000_0101;

        assert_eq!(v5_sampling_interval_to_rate(raw), Some(5));
        assert_eq!(v5_sampling_interval_to_rate(0), None);
    }

    #[test]
    fn test_sampling_probability_converts_to_rate() {
        assert_eq!(sampling_rate_from_probability(0.01), Some(100));
        assert_eq!(sampling_rate_from_probability(1.0), Some(1));
        assert_eq!(sampling_rate_from_probability(0.0), None);
        assert_eq!(sampling_rate_from_probability(1.5), None);
    }

    #[test]
    fn test_is_valid_flow() {
        use crate::listener::is_valid_flow;

        let valid = flowpb::FlowMessage {
            bytes: 100,
            packets: 1,
            ..Default::default()
        };
        let invalid = flowpb::FlowMessage {
            bytes: 0,
            packets: 0,
            ..Default::default()
        };
        assert!(is_valid_flow(&valid));
        assert!(!is_valid_flow(&invalid));
    }

    #[test]
    fn test_protocol_type_name() {
        assert_eq!(protocol_type_name(ProtocolTypes::Tcp), "TCP");
        assert_eq!(protocol_type_name(ProtocolTypes::Udp), "UDP");
    }

    // --- construct_as_path tests ---

    #[test]
    fn test_construct_as_path_full_path() {
        let path = construct_as_path(64512, 64514, 64513);
        assert_eq!(path, vec![64512, 64513, 64514]);
    }

    #[test]
    fn test_construct_as_path_direct_path() {
        // No intermediate AS
        let path = construct_as_path(64512, 64513, 0);
        assert_eq!(path, vec![64512, 64513]);
    }

    #[test]
    fn test_construct_as_path_same_src_dst() {
        // Source and dest are the same (local AS)
        let path = construct_as_path(64512, 64512, 0);
        assert_eq!(path, vec![64512]);
    }

    #[test]
    fn test_construct_as_path_next_hop_same_as_src() {
        // Next hop AS is same as source, should be excluded
        let path = construct_as_path(64512, 64514, 64512);
        assert_eq!(path, vec![64512, 64514]);
    }

    #[test]
    fn test_construct_as_path_next_hop_same_as_dst() {
        // Next hop AS is same as destination, should be excluded
        let path = construct_as_path(64512, 64514, 64514);
        assert_eq!(path, vec![64512, 64514]);
    }

    #[test]
    fn test_construct_as_path_empty_when_all_zero() {
        let path = construct_as_path(0, 0, 0);
        assert_eq!(path, Vec::<u32>::new());
    }

    #[test]
    fn test_construct_as_path_only_source() {
        let path = construct_as_path(64512, 0, 0);
        assert_eq!(path, vec![64512]);
    }

    // --- parse_bgp_communities tests ---

    #[test]
    fn test_parse_bgp_communities_single_u32() {
        let value = FieldValue::DataNumber(DataNumber::U32(0x00010001)); // 1:1
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, vec![0x00010001]);
    }

    #[test]
    fn test_parse_bgp_communities_string_as_value_format() {
        let value = FieldValue::String(make_string_value("65000:100"));
        let communities = parse_bgp_communities(&value);
        // 65000 << 16 | 100 = 0xFDE80064
        assert_eq!(communities, vec![0xFDE80064]);
    }

    #[test]
    fn test_parse_bgp_communities_string_multiple() {
        let value = FieldValue::String(make_string_value("65000:100,65000:200"));
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, vec![0xFDE80064, 0xFDE800C8]);
    }

    #[test]
    fn test_parse_bgp_communities_string_raw_numbers() {
        let value = FieldValue::String(make_string_value("4259840100,4259840200"));
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, vec![4259840100, 4259840200]);
    }

    #[test]
    fn test_parse_bgp_communities_vec_bytes() {
        // 2 communities as bytes (4 bytes each)
        let value = FieldValue::Vec(vec![0xFD, 0xE8, 0x00, 0x64, 0xFD, 0xE8, 0x00, 0xC8]);
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, vec![0xFDE80064, 0xFDE800C8]);
    }

    #[test]
    fn test_parse_bgp_communities_empty_string() {
        let value = FieldValue::String(make_string_value(""));
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, Vec::<u32>::new());
    }

    #[test]
    fn test_parse_bgp_communities_zero_value() {
        let value = FieldValue::DataNumber(DataNumber::U32(0));
        let communities = parse_bgp_communities(&value);
        assert_eq!(communities, Vec::<u32>::new());
    }

    #[test]
    fn bound_sampling_rate_clamps_an_absurd_exporter_value() {
        assert_eq!(
            bound_sampling_rate(u64::MAX, DEFAULT_MAX_SAMPLING_RATE),
            (DEFAULT_MAX_SAMPLING_RATE, true)
        );
    }

    #[test]
    fn bound_sampling_rate_leaves_realistic_rates_untouched() {
        // 1:1, 1:1000 and 1:8192 are ordinary deployments and must not be
        // altered or counted as clamped.
        for rate in [1, 1_000, 8_192, 65_535] {
            assert_eq!(
                bound_sampling_rate(rate, DEFAULT_MAX_SAMPLING_RATE),
                (rate, false),
                "rate {rate} must pass through unchanged"
            );
        }
    }

    #[test]
    fn bound_sampling_rate_treats_the_ceiling_itself_as_in_range() {
        assert_eq!(
            bound_sampling_rate(DEFAULT_MAX_SAMPLING_RATE, DEFAULT_MAX_SAMPLING_RATE),
            (DEFAULT_MAX_SAMPLING_RATE, false)
        );
        assert_eq!(
            bound_sampling_rate(DEFAULT_MAX_SAMPLING_RATE + 1, DEFAULT_MAX_SAMPLING_RATE),
            (DEFAULT_MAX_SAMPLING_RATE, true)
        );
    }

    #[test]
    fn bound_sampling_rate_keeps_the_floor() {
        // A zero rate would erase the flow's volume rather than inflate it.
        assert_eq!(
            bound_sampling_rate(0, DEFAULT_MAX_SAMPLING_RATE),
            (1, false)
        );
        // A degenerate ceiling must still yield a usable multiplier.
        assert_eq!(bound_sampling_rate(0, 0), (1, false));
    }

    /// `samplingProbability` is the sharpest edge: a tiny probability inverts to
    /// a value far beyond `u64`, and Rust's float-to-int `as` saturates rather
    /// than wrapping, so the raw result is `u64::MAX`.
    #[test]
    fn tiny_sampling_probability_saturates_and_is_then_bounded() {
        let raw = sampling_rate_from_probability(1e-300).expect("probability is in range");
        assert_eq!(
            raw,
            u64::MAX,
            "float-to-int conversion is expected to saturate"
        );
        assert_eq!(
            bound_sampling_rate(raw, DEFAULT_MAX_SAMPLING_RATE),
            (DEFAULT_MAX_SAMPLING_RATE, true)
        );
    }

    #[test]
    fn ordinary_sampling_probability_is_unaffected() {
        assert_eq!(sampling_rate_from_probability(0.001), Some(1_000));
        assert_eq!(
            bound_sampling_rate(1_000, DEFAULT_MAX_SAMPLING_RATE),
            (1_000, false)
        );
        // Out-of-range probabilities are rejected before any bounding.
        assert_eq!(sampling_rate_from_probability(0.0), None);
        assert_eq!(sampling_rate_from_probability(-1.0), None);
        assert_eq!(sampling_rate_from_probability(1.5), None);
        assert_eq!(sampling_rate_from_probability(f64::NAN), None);
    }

    #[test]
    fn v5_interval_cannot_exceed_its_14_bit_field() {
        // The mode bits in the top two bits must not leak into the rate, which
        // is why v5 is not a vector for inflation.
        assert_eq!(v5_sampling_interval_to_rate(0xffff), Some(0x3fff));
        assert_eq!(v5_sampling_interval_to_rate(0), None);
    }

    fn ie(kind: IANAIPFixField, value: u64) -> IPFixFieldPair {
        (
            IPFixField::IANA(kind),
            FieldValue::DataNumber(DataNumber::U64(value)),
        )
    }

    fn convert_ipfix(
        rates: &mut SamplerRates,
        now_ns: u64,
        body: FlowSetBody,
    ) -> Vec<flowpb::FlowMessage> {
        use netflow_parser::variable_versions::ipfix::{FlowSet, FlowSetHeader, Header, IPFix};

        let packet = NetflowPacket::IPFix(IPFix {
            header: Header {
                version: 10,
                length: 16,
                export_time: 0,
                sequence_number: 1,
                observation_domain_id: 7,
            },
            flowsets: vec![FlowSet {
                header: FlowSetHeader {
                    header_id: 256,
                    length: 4,
                },
                body,
            }],
        });
        let peer: SocketAddr = "192.0.2.9:4739".parse().unwrap();
        Converter::new(packet, peer, now_ns, 5, DEFAULT_MAX_SAMPLING_RATE)
            .convert_with_sampler_rates(rates)
    }

    /// Selector 1 at 1:100, replaced by selector 2 at 1:512. While both have
    /// been seen inside the refresh window, a flow that names neither stays
    /// on the fallback. Once selector 1 ages out, selector 2 is the domain rate.
    #[test]
    fn retired_selector_ages_out_and_the_latest_refresh_wins() {
        use netflow_parser::variable_versions::ipfix::{Data, OptionsData};

        let options = |id: u64, rate: u64| {
            FlowSetBody::OptionsData(OptionsData::new(vec![vec![
                ie(IANAIPFixField::SelectorId, id),
                ie(IANAIPFixField::SamplingInterval, rate),
            ]]))
        };
        let unnamed = FlowSetBody::Data(Data::new(vec![vec![ie(
            IANAIPFixField::OctetDeltaCount,
            1500,
        )]]));
        let named = FlowSetBody::Data(Data::new(vec![vec![
            ie(IANAIPFixField::OctetDeltaCount, 1500),
            ie(IANAIPFixField::SelectorId, 1),
        ]]));
        let rate_of = |rates: &mut SamplerRates, now_ns: u64, body: FlowSetBody| {
            let messages = convert_ipfix(rates, now_ns, body);
            assert_eq!(messages.len(), 1);
            messages[0].sampling_rate
        };

        let mut rates = SamplerRates::default();
        let window = u64::try_from(OPTIONS_REFRESH_WINDOW.as_nanos()).unwrap();
        let t0 = 1_000_000_000_000u64;

        assert!(convert_ipfix(&mut rates, t0, options(1, 100)).is_empty());
        assert_eq!(rate_of(&mut rates, t0, unnamed.clone()), 100);
        assert_eq!(rates.options_rates_learned, 1);
        assert!(convert_ipfix(&mut rates, t0, options(1, 100)).is_empty());
        assert_eq!(rates.options_rates_learned, 1);

        assert!(convert_ipfix(&mut rates, t0 + 1, options(2, 512)).is_empty());
        assert_eq!(rates.options_rates_learned, 2);
        assert_eq!(
            rate_of(&mut rates, t0 + 1, unnamed.clone()),
            5,
            "both selectors are still inside the window and disagree"
        );
        assert_eq!(
            rate_of(&mut rates, t0 + window, unnamed.clone()),
            512,
            "selector 1 has been silent for the window, so selector 2 wins"
        );
        assert_eq!(
            rate_of(&mut rates, t0 + window, named),
            100,
            "a flow that names selector 1 still uses that selector"
        );
    }

    /// Selectors past the per-source cap do not vote. After the window they
    /// no longer occupy a slot, so a new declaration can.
    #[test]
    fn selector_cap_rejects_extra_votes_until_they_age_out() {
        use std::net::Ipv4Addr;

        let source = SourceId::Legacy(SocketAddr::new(IpAddr::V4(Ipv4Addr::new(192, 0, 2, 9)), 9));
        let sampling = |id: u64, rate: u64| SamplingFields {
            sampler_id: Some(id),
            interval: Some(rate),
            ..SamplingFields::default()
        };
        let mut rates = SamplerRates::default();
        let t0 = 1_000_000_000_000u64;
        for id in 1..=MAX_SELECTORS_PER_SOURCE as u64 {
            rates.learn_options(&source, &sampling(id, 100), None, t0);
        }
        assert_eq!(rates.learned_rate(&source, None, 0, 0, t0), Some(100));
        assert_eq!(rates.rejected_inserts, 0);

        let overflow = MAX_SELECTORS_PER_SOURCE as u64 + 1;
        rates.learn_options(&source, &sampling(overflow, 512), None, t0);
        assert_eq!(rates.rejected_inserts, 1);
        assert_eq!(
            rates.learned_rate(&source, None, 0, 0, t0),
            Some(100),
            "a selector past the cap does not vote on the domain rate"
        );
        assert_eq!(
            rates.learned_rate(&source, Some(overflow), 0, 0, t0),
            Some(512),
            "a flow that names the extra selector still uses its stored rate"
        );
        rates.learn_options(&source, &sampling(1, 100), None, t0);
        assert_eq!(
            rates.rejected_inserts, 1,
            "refreshing a stored selector is not another rejection"
        );

        let window = u64::try_from(OPTIONS_REFRESH_WINDOW.as_nanos()).unwrap();
        let later = overflow + 1;
        rates.learn_options(&source, &sampling(later, 512), None, t0 + window);
        assert_eq!(rates.rejected_inserts, 1);
        assert_eq!(
            rates.learned_rate(&source, None, 0, 0, t0 + window),
            Some(512),
            "expired selectors free a slot and the new declaration wins"
        );
    }

    #[test]
    fn options_rate_metric_ignores_refreshes_and_rejected_inserts() {
        use std::net::Ipv4Addr;

        let sampling = |rate: u64| SamplingFields {
            interval: Some(rate),
            ..SamplingFields::default()
        };
        let source_at =
            |index: u32| SourceId::Legacy(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(index)), 9));
        let mut rates = SamplerRates::default();
        for index in 0..MAX_SAMPLER_RATE_ENTRIES as u32 {
            rates.learn_options(&source_at(index), &sampling(8), None, 1);
        }
        assert_eq!(rates.options_rates_learned, MAX_SAMPLER_RATE_ENTRIES as u64);
        assert_eq!(rates.rejected_inserts, 0);

        rates.learn_options(&source_at(u32::MAX), &sampling(8), None, 1);
        assert_eq!(
            rates.options_rates_learned, MAX_SAMPLER_RATE_ENTRIES as u64,
            "a rejected insert is not a learned rate"
        );
        assert_eq!(rates.rejected_inserts, 1);

        let first = source_at(0);
        rates.learn_options(&first, &sampling(8), None, 2);
        assert_eq!(rates.options_rates_learned, MAX_SAMPLER_RATE_ENTRIES as u64);
        rates.learn_options(&first, &sampling(9), None, 3);
        assert_eq!(
            rates.options_rates_learned,
            MAX_SAMPLER_RATE_ENTRIES as u64 + 1
        );

        rates.learn_options(&first, &sampling(100), Some(10), 4);
        rates.learn_options(&first, &sampling(1000), Some(20), 4);
        assert_eq!(rates.learned_rate(&first, None, 10, 0, 4), Some(100));
        assert_eq!(rates.learned_rate(&first, None, 20, 0, 4), Some(1000));
        assert_eq!(
            rates.learned_rate(&first, None, 99, 20, 4),
            Some(1000),
            "output is used when the input interface has no entry"
        );
        assert_eq!(rates.learned_rate(&first, None, 99, 1, 4), Some(9));
        rates.remove_source(&first);
        assert_eq!(rates.learned_rate(&first, None, 10, 20, 4), None);
        assert_eq!(rates.learned_rate(&first, None, 0, 0, 4), None);
    }
}
