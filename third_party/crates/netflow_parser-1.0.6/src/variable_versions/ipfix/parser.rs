//! IPFixParser — template-cached IPFIX parser with pending flow support.
//!
//! Type definitions live in the parent `ipfix` module (`mod.rs`).
//! Parsing impl blocks for IPFIX types (FlowSetBody, FieldParser, TemplateField, etc.)
//! are also defined here.

use super::{
    CommonTemplate, DATA_TEMPLATE_IPFIX_ID, DEFAULT_MAX_TEMPLATE_CACHE_SIZE, Data, FieldParser,
    FlowSet, FlowSetBody, FlowSetHeader, IPFix, IPFixFieldPair, IPFixParser, MAX_FIELD_COUNT,
    NoTemplateInfo, OPTIONS_TEMPLATE_IPFIX_ID, OptionsData, OptionsTemplate, Template,
    TemplateField,
};
use crate::template_store::{
    TemplateKind, TemplateStore, TemplateStoreKey, decode_ipfix_options_template,
    decode_ipfix_template, decode_v9_options_template, decode_v9_template,
    encode_ipfix_options_template, encode_ipfix_template, encode_v9_options_template,
    encode_v9_template,
};
use crate::variable_versions::config::DEFAULT_MAX_RECORDS_PER_FLOWSET;
use crate::variable_versions::enterprise_registry::EnterpriseFieldRegistry;
use crate::variable_versions::field_value::FieldValue;
use crate::variable_versions::lazy_lru::LazyLruCache;
use crate::variable_versions::metrics::CacheMetricsInner;
use crate::variable_versions::output_budget::{PendingOutputError, PendingOutputPreflight};
use crate::variable_versions::template_events::TemplateProtocol;
use crate::variable_versions::ttl::{TemplateWithTtl, TtlConfig};
use crate::variable_versions::v9::{
    DATA_TEMPLATE_V9_ID, Data as V9Data, OPTIONS_TEMPLATE_V9_ID, OptionsData as V9OptionsData,
    OptionsTemplate as V9OptionsTemplate, Template as V9Template,
};
use crate::variable_versions::wire::RecordBodyKind;
use crate::variable_versions::{
    Config, ConfigError, DecodedOutputBudget, ParserConfig, ParserFields, PendingFlowCache,
    PendingFlowEntry, PendingFlowsConfig,
};
use crate::{NetflowError, NetflowPacket, ParsedNetflow};

use crate::variable_versions::fast_parse::{parse_u8, parse_u16_be};
use nom::IResult;
use nom::combinator::complete;
use nom::multi::many0;
use nom_derive::Parse;
use std::num::NonZeroUsize;
use std::sync::Arc;

const MIN_STORE_REPLAY_TRIGGER_MESSAGE_LENGTH: u16 = 20;
const MIN_TEMPLATE_REPLAY_TRIGGER_MESSAGE_LENGTH: u16 = 28;

enum IpfixPendingReplayOutcome {
    Replayed { new_header_length: u16 },
    TemporarilyDoesNotFit,
    Failed,
}

impl From<PendingOutputError> for IpfixPendingReplayOutcome {
    fn from(error: PendingOutputError) -> Self {
        match error {
            PendingOutputError::TemporarilyDoesNotFit => Self::TemporarilyDoesNotFit,
            PendingOutputError::NeverFits | PendingOutputError::Invalid => Self::Failed,
        }
    }
}

impl Default for IPFixParser {
    fn default() -> Self {
        // Safe to unwrap because DEFAULT_MAX_TEMPLATE_CACHE_SIZE is non-zero
        let config = Config {
            max_template_cache_size: DEFAULT_MAX_TEMPLATE_CACHE_SIZE,
            max_field_count: MAX_FIELD_COUNT,
            max_template_total_size: usize::from(u16::MAX),
            max_error_sample_size: 256,
            max_records_per_flowset: DEFAULT_MAX_RECORDS_PER_FLOWSET,
            max_decoded_field_values_per_message:
                crate::DEFAULT_MAX_DECODED_FIELD_VALUES_PER_MESSAGE,
            max_decoded_field_payload_bytes_per_message:
                crate::DEFAULT_MAX_DECODED_FIELD_PAYLOAD_BYTES_PER_MESSAGE,
            ttl_config: None,
            enterprise_registry: Arc::new(EnterpriseFieldRegistry::new()),
            pending_flows_config: None,
            template_store: None,
            template_store_scope: Arc::from(""),
        };

        match Self::try_new(config) {
            Ok(parser) => parser,
            Err(e) => unreachable!("hardcoded default config must be valid: {e}"),
        }
    }
}

impl IPFixParser {
    pub(crate) fn start_decoded_output_message(&mut self) {
        self.decoded_output_budget.reset();
    }

    pub(crate) fn decoded_output_limit_was_exceeded(&self) -> bool {
        self.decoded_output_budget.is_exceeded()
    }

    /// Validates a configuration without allocating parser internals.
    pub fn validate_config(config: &Config) -> Result<(), ConfigError> {
        config.validate()
    }

    /// Create a new IPFixParser with a custom template cache size and optional TTL configuration.
    ///
    /// # Arguments
    /// * `config` - Configuration struct containing max_template_cache_size and optional ttl_config
    ///
    /// # Errors
    /// Returns `ConfigError` if the template cache size or either decoded-output
    /// limit is zero.
    pub fn try_new(config: Config) -> Result<Self, ConfigError> {
        let cache_size = NonZeroUsize::new(config.max_template_cache_size).ok_or(
            ConfigError::InvalidCacheSize(config.max_template_cache_size),
        )?;
        if config.max_decoded_field_values_per_message == 0 {
            return Err(ConfigError::InvalidDecodedFieldValueLimit(0));
        }
        if config.max_decoded_field_payload_bytes_per_message == 0 {
            return Err(ConfigError::InvalidDecodedFieldPayloadByteLimit(0));
        }

        let pending_flows = config
            .pending_flows_config
            .map(PendingFlowCache::new)
            .transpose()?;

        Ok(Self {
            templates: LazyLruCache::new(cache_size),
            v9_templates: LazyLruCache::new(cache_size),
            ipfix_options_templates: LazyLruCache::new(cache_size),
            v9_options_templates: LazyLruCache::new(cache_size),
            ttl_config: config.ttl_config,
            max_template_cache_size: config.max_template_cache_size,
            max_field_count: config.max_field_count,
            max_template_total_size: config.max_template_total_size,
            max_error_sample_size: config.max_error_sample_size,
            max_records_per_flowset: config.max_records_per_flowset,
            decoded_output_budget: DecodedOutputBudget::new(
                config.max_decoded_field_values_per_message,
                config.max_decoded_field_payload_bytes_per_message,
            ),
            enterprise_registry: config.enterprise_registry,
            metrics: CacheMetricsInner::new(),
            pending_flows,
            template_store: config.template_store,
            template_store_scope: config.template_store_scope,
            restored_templates: Vec::new(),
        })
    }

    /// Override the scope written into [`TemplateStoreKey`]s for store
    /// reads/writes. Used by `AutoScopedParser` to give each per-source
    /// parser an exporter-specific scope.
    pub(crate) fn set_template_store_scope(&mut self, scope: Arc<str>) {
        self.template_store_scope = scope;
    }

    /// Write-through helper: persist a freshly learned template to the
    /// secondary store, if one is configured. Backend failures are recorded
    /// in metrics but do not abort packet parsing — the in-process LRU has
    /// already been updated by the caller.
    ///
    /// Holds `store` as a borrow (no `Arc::clone`); `&self.template_store`
    /// and `&mut self.metrics` are disjoint fields so both borrows coexist.
    fn put_to_store(&mut self, kind: TemplateKind, template_id: u16, bytes: Vec<u8>) {
        let Some(store) = self.template_store.as_ref() else {
            return;
        };
        let key =
            TemplateStoreKey::new(Arc::clone(&self.template_store_scope), kind, template_id);
        if store.put(&key, &bytes).is_err() {
            self.metrics.record_template_store_backend_error();
        }
    }

    /// Best-effort removal of an LRU-evicted, withdrawn, or cleared entry
    /// from the secondary store. No-op when no store is configured.
    /// Backend failures are recorded in metrics.
    fn evict_from_store(&mut self, kind: TemplateKind, template_id: u16) {
        let Some(store) = self.template_store.as_ref() else {
            return;
        };
        let key =
            TemplateStoreKey::new(Arc::clone(&self.template_store_scope), kind, template_id);
        if store.remove(&key).is_err() {
            self.metrics.record_template_store_backend_error();
        }
    }

    /// Install a read-through-recovered template into the in-process LRU
    /// and queue a Restored event for hook firing. If the LRU eviction
    /// returns a *different* key (i.e. the cache was full), mirror the
    /// removal back to the secondary store and bump the eviction metric so
    /// the primary and secondary tiers stay consistent.
    ///
    /// Takes raw `&mut` borrows of the cache, metrics, and event buffer
    /// rather than `&mut self` so that the caller can keep separate borrows
    /// of `self.templates` (or whichever cache) and `self.metrics` /
    /// `self.restored_templates` live simultaneously without the borrow
    /// checker reaching for splits.
    #[allow(clippy::too_many_arguments)]
    fn install_restored<T>(
        cache: &mut LazyLruCache<crate::variable_versions::TemplateId, TemplateWithTtl<Arc<T>>>,
        template_id: u16,
        arc: &Arc<T>,
        ttl_enabled: bool,
        metrics: &mut CacheMetricsInner,
        store: &Arc<dyn TemplateStore>,
        scope: &Arc<str>,
        kind: TemplateKind,
        restored: &mut Vec<(TemplateProtocol, u16)>,
        protocol: TemplateProtocol,
    ) {
        let wrapped = TemplateWithTtl::new(Arc::clone(arc), ttl_enabled);
        if let Some((evicted_key, _)) = cache.push(template_id, wrapped)
            && evicted_key != template_id
        {
            metrics.record_eviction();
            let key = TemplateStoreKey::new(Arc::clone(scope), kind, evicted_key);
            if store.remove(&key).is_err() {
                metrics.record_template_store_backend_error();
            }
        }
        metrics.record_template_store_restored();
        restored.push((protocol, template_id));
    }

    /// Read-through: on a primary-cache miss for an IPFIX data template,
    /// consult the secondary store. On hit the decoded template is pushed
    /// into the in-process LRU (so subsequent flowsets are served from the
    /// hot path) and a `Restored` event is queued for hook firing. On
    /// codec failure the corrupted entry is removed so that a fresh
    /// template announce can repopulate it cleanly. Returns `None` for
    /// "not in store", "backend error", or "decoded but rejected by parser
    /// limits" — the data record will then take the existing miss path.
    ///
    /// `store` is borrowed (no `Arc::clone`); every other field used
    /// (`template_store_scope`, `metrics`, `templates`, `restored_templates`,
    /// `ttl_config`, `max_field_count`, `max_template_total_size`) is
    /// accessed via direct field access so the borrow checker can split
    /// disjoint fields. We avoid `&self`/`&mut self` method calls inside
    /// the borrow so the whole-self re-borrow that would force a clone
    /// never happens.
    fn fetch_ipfix_template_from_store(&mut self, template_id: u16) -> Option<Arc<Template>> {
        let store = self.template_store.as_ref()?;
        let key = TemplateStoreKey::new(
            Arc::clone(&self.template_store_scope),
            TemplateKind::IpfixData,
            template_id,
        );
        let bytes = match store.get(&key) {
            Ok(Some(b)) => b,
            Ok(None) => return None,
            Err(_) => {
                self.metrics.record_template_store_backend_error();
                return None;
            }
        };
        let template = match decode_ipfix_template(&bytes) {
            Ok(t) => t,
            Err(_) => {
                self.metrics.record_template_store_codec_error();
                if store.remove(&key).is_err() {
                    self.metrics.record_template_store_backend_error();
                }
                return None;
            }
        };
        // Inline the validation rule by passing limits explicitly — calling
        // `template.is_valid(self)` would re-borrow whole self and conflict
        // with the `store` borrow.
        if !<Template as CommonTemplate>::is_valid_with_limits(
            &template,
            self.max_field_count,
            self.max_template_total_size,
        ) {
            return None;
        }
        let arc = Arc::new(template);
        let ttl_enabled = self.ttl_config.is_some();
        Self::install_restored(
            &mut self.templates,
            template_id,
            &arc,
            ttl_enabled,
            &mut self.metrics,
            store,
            &self.template_store_scope,
            TemplateKind::IpfixData,
            &mut self.restored_templates,
            TemplateProtocol::Ipfix,
        );
        Some(arc)
    }

    /// Read-through for IPFIX options templates. Same protocol as
    /// `fetch_ipfix_template_from_store`; see there for error and
    /// borrow-split semantics.
    fn fetch_ipfix_options_template_from_store(
        &mut self,
        template_id: u16,
    ) -> Option<Arc<OptionsTemplate>> {
        let store = self.template_store.as_ref()?;
        let key = TemplateStoreKey::new(
            Arc::clone(&self.template_store_scope),
            TemplateKind::IpfixOptions,
            template_id,
        );
        let bytes = match store.get(&key) {
            Ok(Some(b)) => b,
            Ok(None) => return None,
            Err(_) => {
                self.metrics.record_template_store_backend_error();
                return None;
            }
        };
        let template = match decode_ipfix_options_template(&bytes) {
            Ok(t) => t,
            Err(_) => {
                self.metrics.record_template_store_codec_error();
                if store.remove(&key).is_err() {
                    self.metrics.record_template_store_backend_error();
                }
                return None;
            }
        };
        if !<OptionsTemplate as CommonTemplate>::is_valid_with_limits(
            &template,
            self.max_field_count,
            self.max_template_total_size,
        ) {
            return None;
        }
        let arc = Arc::new(template);
        let ttl_enabled = self.ttl_config.is_some();
        Self::install_restored(
            &mut self.ipfix_options_templates,
            template_id,
            &arc,
            ttl_enabled,
            &mut self.metrics,
            store,
            &self.template_store_scope,
            TemplateKind::IpfixOptions,
            &mut self.restored_templates,
            TemplateProtocol::Ipfix,
        );
        Some(arc)
    }

    /// Read-through for V9-style data templates embedded in IPFIX messages
    /// (RFC 5101 hybrid mode). Same protocol as
    /// `fetch_ipfix_template_from_store`; validation uses the canonical
    /// `V9Template::is_valid_with_limits` helper to stay in sync with the
    /// live-parse path in `parse_templates`.
    fn fetch_v9_template_from_store(&mut self, template_id: u16) -> Option<Arc<V9Template>> {
        let store = self.template_store.as_ref()?;
        let key = TemplateStoreKey::new(
            Arc::clone(&self.template_store_scope),
            TemplateKind::IpfixV9Data,
            template_id,
        );
        let bytes = match store.get(&key) {
            Ok(Some(b)) => b,
            Ok(None) => return None,
            Err(_) => {
                self.metrics.record_template_store_backend_error();
                return None;
            }
        };
        let template = match decode_v9_template(&bytes) {
            Ok(t) => t,
            Err(_) => {
                self.metrics.record_template_store_codec_error();
                if store.remove(&key).is_err() {
                    self.metrics.record_template_store_backend_error();
                }
                return None;
            }
        };
        if !template.is_valid_with_limits(self.max_field_count, self.max_template_total_size) {
            return None;
        }
        let arc = Arc::new(template);
        let ttl_enabled = self.ttl_config.is_some();
        Self::install_restored(
            &mut self.v9_templates,
            template_id,
            &arc,
            ttl_enabled,
            &mut self.metrics,
            store,
            &self.template_store_scope,
            TemplateKind::IpfixV9Data,
            &mut self.restored_templates,
            TemplateProtocol::V9,
        );
        Some(arc)
    }

    /// Read-through for V9-style options templates embedded in IPFIX
    /// messages. Same protocol as `fetch_v9_template_from_store`.
    fn fetch_v9_options_template_from_store(
        &mut self,
        template_id: u16,
    ) -> Option<Arc<V9OptionsTemplate>> {
        let store = self.template_store.as_ref()?;
        let key = TemplateStoreKey::new(
            Arc::clone(&self.template_store_scope),
            TemplateKind::IpfixV9Options,
            template_id,
        );
        let bytes = match store.get(&key) {
            Ok(Some(b)) => b,
            Ok(None) => return None,
            Err(_) => {
                self.metrics.record_template_store_backend_error();
                return None;
            }
        };
        let template = match decode_v9_options_template(&bytes) {
            Ok(t) => t,
            Err(_) => {
                self.metrics.record_template_store_codec_error();
                if store.remove(&key).is_err() {
                    self.metrics.record_template_store_backend_error();
                }
                return None;
            }
        };
        if !template.is_valid_with_limits(self.max_field_count, self.max_template_total_size) {
            return None;
        }
        let arc = Arc::new(template);
        let ttl_enabled = self.ttl_config.is_some();
        Self::install_restored(
            &mut self.v9_options_templates,
            template_id,
            &arc,
            ttl_enabled,
            &mut self.metrics,
            store,
            &self.template_store_scope,
            TemplateKind::IpfixV9Options,
            &mut self.restored_templates,
            TemplateProtocol::V9,
        );
        Some(arc)
    }
}

impl ParserFields for IPFixParser {
    fn set_max_template_cache_size_field(&mut self, size: usize) {
        self.max_template_cache_size = size;
    }
    fn set_max_field_count_field(&mut self, count: usize) {
        self.max_field_count = count;
    }
    fn set_max_template_total_size_field(&mut self, size: usize) {
        self.max_template_total_size = size;
    }
    fn set_max_error_sample_size_field(&mut self, size: usize) {
        self.max_error_sample_size = size;
    }
    fn set_max_records_per_flowset_field(&mut self, count: usize) {
        self.max_records_per_flowset = count;
    }
    fn set_decoded_output_limits_fields(&mut self, values: usize, payload_bytes: usize) {
        self.decoded_output_budget.set_limits(values, payload_bytes);
    }
    fn set_ttl_config_field(&mut self, config: Option<TtlConfig>) {
        self.ttl_config = config;
    }
    fn set_enterprise_registry(&mut self, registry: Arc<EnterpriseFieldRegistry>) {
        self.enterprise_registry = registry;
    }
    fn pending_flows(&self) -> &Option<PendingFlowCache> {
        &self.pending_flows
    }
    fn pending_flows_mut(&mut self) -> &mut Option<PendingFlowCache> {
        &mut self.pending_flows
    }
    fn metrics_mut(&mut self) -> &mut CacheMetricsInner {
        &mut self.metrics
    }
}

impl ParserConfig for IPFixParser {
    fn set_pending_flows_config(
        &mut self,
        config: Option<PendingFlowsConfig>,
    ) -> Result<(), ConfigError> {
        match config {
            Some(pf_config) => {
                if let Some(ref mut cache) = self.pending_flows {
                    cache.resize(pf_config, &mut self.metrics)?;
                } else {
                    self.pending_flows = Some(PendingFlowCache::new(pf_config)?);
                }
            }
            None => {
                // Record all cached entries as dropped before discarding.
                if let Some(ref cache) = self.pending_flows {
                    let count = cache.count();
                    if count > 0 {
                        self.metrics.record_pending_dropped_n(count as u64);
                    }
                }
                self.pending_flows = None;
            }
        }
        Ok(())
    }

    fn resize_template_caches(&mut self, cache_size: NonZeroUsize) {
        self.templates.resize(cache_size);
        self.v9_templates.resize(cache_size);
        self.ipfix_options_templates.resize(cache_size);
        self.v9_options_templates.resize(cache_size);
    }
}

impl IPFixParser {
    /// Parse an IPFIX message from raw bytes, using cached templates to decode data records.
    pub(crate) fn parse<'a>(&mut self, packet: &'a [u8]) -> ParsedNetflow<'a> {
        // Reset the per-parse restored-templates buffer so the next call
        // sees only what was restored during *this* packet.
        self.restored_templates.clear();
        match IPFix::parse(packet, self) {
            Ok((remaining, mut ipfix)) => {
                self.process_pending_flows(&mut ipfix);
                ParsedNetflow::Success {
                    packet: NetflowPacket::IPFix(ipfix),
                    remaining,
                }
            }
            Err(e) => {
                let error = if let Some(exceeded) = self.decoded_output_budget.take_exceeded() {
                    NetflowError::DecodedOutputLimitExceeded {
                        protocol: TemplateProtocol::Ipfix,
                        limit: exceeded.limit,
                        configured: exceeded.configured,
                        attempted: exceeded.attempted,
                    }
                } else {
                    NetflowError::Partial {
                        message: format!("IPFIX parse error: {}", e),
                    }
                };
                ParsedNetflow::Error { error }
            }
        }
    }

    fn process_pending_flows(&mut self, ipfix: &mut IPFix) {
        let Some(mut pending_cache) = self.pending_flows.take() else {
            return;
        };
        let mut learned = Self::cache_notemplate_ipfix_flowsets(
            ipfix,
            &mut pending_cache,
            &mut self.metrics,
            self.max_error_sample_size,
        );
        // Templates restored via the secondary store during this packet
        // should also drive pending-flow replay — see the matching block in
        // V9Parser::process_pending_flows for rationale.
        for &(_, id) in &self.restored_templates {
            if !learned.contains(&id) {
                learned.push(id);
            }
        }
        self.replay_ipfix_pending_flows(ipfix, &mut pending_cache, &learned);
        self.pending_flows = Some(pending_cache);
    }

    /// Drain the list of templates restored via the secondary store during
    /// the most recent parse. Used by `NetflowParser::fire_template_events`
    /// to emit `TemplateEvent::Restored` for each.
    pub(crate) fn drain_restored_templates(&mut self) -> Vec<(TemplateProtocol, u16)> {
        std::mem::take(&mut self.restored_templates)
    }

    /// Single pass: cache NoTemplate raw data, collect learned template IDs,
    /// remove successfully-cached flowsets, and adjust header.length.
    fn cache_notemplate_ipfix_flowsets(
        ipfix: &mut IPFix,
        cache: &mut PendingFlowCache,
        metrics: &mut CacheMetricsInner,
        max_error_sample_size: usize,
    ) -> Vec<u16> {
        let mut learned_template_ids: Vec<u16> = Vec::new();
        let mut remove_mask: Vec<bool> = vec![false; ipfix.flowsets.len()];
        for (i, flowset) in ipfix.flowsets.iter_mut().enumerate() {
            match &mut flowset.body {
                FlowSetBody::NoTemplate(info) => {
                    // Reject flowsets with impossibly small headers (RFC minimum is 4).
                    // Also reject truncated raw_data (oversized entry at parse time).
                    // The flowset is kept in output as diagnostic data.
                    if flowset.header.length < 4 {
                        metrics.record_pending_dropped();
                        continue;
                    }
                    let body_len = (flowset.header.length as usize) - 4;
                    if info.raw_data.len() < body_len {
                        metrics.record_pending_dropped();
                        continue;
                    }
                    let raw_data = std::mem::take(&mut info.raw_data);
                    if let Some(mut returned) = cache.cache(info.template_id, raw_data, metrics)
                    {
                        // Truncate rejected data to diagnostic size so
                        // callers don't hold the full (potentially large)
                        // buffer that was not cached.
                        let full_len = returned.len();
                        returned.truncate(max_error_sample_size);
                        if returned.len() < full_len {
                            info.truncated = true;
                        }
                        info.raw_data = returned;
                    } else {
                        remove_mask[i] = true;
                    }
                }
                FlowSetBody::Template(t) => {
                    learned_template_ids.push(t.template_id);
                }
                FlowSetBody::Templates(ts) => {
                    for t in ts.iter() {
                        learned_template_ids.push(t.template_id);
                    }
                }
                FlowSetBody::V9Template(t) => {
                    learned_template_ids.push(t.template_id);
                }
                FlowSetBody::V9Templates(ts) => {
                    for t in ts.iter() {
                        learned_template_ids.push(t.template_id);
                    }
                }
                FlowSetBody::OptionsTemplate(t) => {
                    learned_template_ids.push(t.template_id);
                }
                FlowSetBody::OptionsTemplates(ts) => {
                    for t in ts.iter() {
                        learned_template_ids.push(t.template_id);
                    }
                }
                FlowSetBody::V9OptionsTemplate(t) => {
                    learned_template_ids.push(t.template_id);
                }
                FlowSetBody::V9OptionsTemplates(ts) => {
                    for t in ts.iter() {
                        learned_template_ids.push(t.template_id);
                    }
                }
                _ => {}
            }
        }
        // Remove successfully-cached flowsets and reconcile header length.
        let mut mask_iter = remove_mask.into_iter();
        ipfix
            .flowsets
            .retain(|_| !mask_iter.next().unwrap_or(false));
        // Reconcile header length from remaining flowsets (avoids drift from
        // saturating arithmetic on corrupt input).
        let body_len: u16 = ipfix
            .flowsets
            .iter()
            .fold(0u16, |acc, fs| acc.saturating_add(fs.header.length));
        // IPFIX header is 16 bytes; total message length = header + body.
        ipfix.header.length = 16u16.saturating_add(body_len);
        learned_template_ids
    }

    /// Replay pending flows for each newly learned template.
    fn replay_ipfix_pending_flows(
        &mut self,
        ipfix: &mut IPFix,
        cache: &mut PendingFlowCache,
        learned: &[u16],
    ) {
        for &template_id in learned {
            let entries = cache.drain(template_id, &mut self.metrics);
            let mut entries = entries.into_iter();
            while let Some(entry) = entries.next() {
                // Bound flowset count, consistent with V9 replay.
                if ipfix.flowsets.len() >= u16::MAX as usize {
                    let mut retained = Vec::with_capacity(entries.len().saturating_add(1));
                    retained.push(entry);
                    retained.extend(entries);
                    cache.restore_replay_suffix(template_id, retained);
                    break;
                }
                match self.try_replay_ipfix_flow(
                    &mut ipfix.flowsets,
                    template_id,
                    &entry,
                    ipfix.header.length,
                ) {
                    IpfixPendingReplayOutcome::Replayed { new_header_length } => {
                        self.metrics.record_pending_replayed();
                        ipfix.header.length = new_header_length;
                    }
                    IpfixPendingReplayOutcome::Failed => {
                        self.metrics.record_pending_replay_failed();
                    }
                    IpfixPendingReplayOutcome::TemporarilyDoesNotFit => {
                        let mut retained = Vec::with_capacity(entries.len().saturating_add(1));
                        retained.push(entry);
                        retained.extend(entries);
                        cache.restore_replay_suffix(template_id, retained);
                        break;
                    }
                }
            }
        }
    }

    /// Try to replay a pending flow entry using available templates.
    fn try_replay_ipfix_flow(
        &mut self,
        flowsets: &mut Vec<FlowSet>,
        template_id: u16,
        entry: &PendingFlowEntry,
        current_header_length: u16,
    ) -> IpfixPendingReplayOutcome {
        // Use peek_valid_template to avoid false LRU promotion on failed parse.
        // Preserve the established lookup priority and promote only after a
        // complete entry has been materialized within the message budget.
        self.try_replay_ipfix_data(flowsets, template_id, entry, current_header_length)
            .or_else(|| {
                self.try_replay_ipfix_options_data(
                    flowsets,
                    template_id,
                    entry,
                    current_header_length,
                )
            })
            .or_else(|| {
                self.try_replay_embedded_v9_data(
                    flowsets,
                    template_id,
                    entry,
                    current_header_length,
                )
            })
            .or_else(|| {
                self.try_replay_embedded_v9_options_data(
                    flowsets,
                    template_id,
                    entry,
                    current_header_length,
                )
            })
            .unwrap_or(IpfixPendingReplayOutcome::Failed)
    }

    fn try_replay_ipfix_data(
        &mut self,
        flowsets: &mut Vec<FlowSet>,
        template_id: u16,
        entry: &PendingFlowEntry,
        current_header_length: u16,
    ) -> Option<IpfixPendingReplayOutcome> {
        let template = crate::variable_versions::peek_valid_template(
            &mut self.templates,
            &template_id,
            &self.ttl_config,
            &mut self.metrics,
        )?;
        let preflight = crate::variable_versions::output_budget::measure_variable_output(
            &entry.raw_data,
            template.get_fields(),
            self.max_records_per_flowset,
            |field| field.field_length,
            RecordBodyKind::Ipfix,
        );
        let (preflight, flowset_length, new_header_length) = match self
            .validate_ipfix_pending_replay(
                preflight,
                entry.raw_data.len(),
                current_header_length,
            ) {
            Ok(result) => result,
            Err(PendingOutputError::Invalid) => return None,
            Err(error) => return Some(error.into()),
        };
        let (mut data, padding_len) =
            match self
                .decoded_output_budget
                .materialize_pending(Some(preflight), |budget| {
                    Data::parse_with_registry_and_budget(
                        &entry.raw_data,
                        &template,
                        &self.enterprise_registry,
                        self.max_records_per_flowset,
                        budget,
                    )
                }) {
                Ok(result) => result,
                Err(PendingOutputError::Invalid) => return None,
                Err(error) => return Some(error.into()),
            };
        data.padding = entry.raw_data[entry.raw_data.len() - padding_len..].to_vec();
        self.templates.promote(&template_id);
        flowsets.push(Self::replayed_flowset(
            template_id,
            flowset_length,
            FlowSetBody::Data(data),
        ));
        Some(IpfixPendingReplayOutcome::Replayed { new_header_length })
    }

    fn try_replay_ipfix_options_data(
        &mut self,
        flowsets: &mut Vec<FlowSet>,
        template_id: u16,
        entry: &PendingFlowEntry,
        current_header_length: u16,
    ) -> Option<IpfixPendingReplayOutcome> {
        let template = crate::variable_versions::peek_valid_template(
            &mut self.ipfix_options_templates,
            &template_id,
            &self.ttl_config,
            &mut self.metrics,
        )?;
        let preflight = crate::variable_versions::output_budget::measure_variable_output(
            &entry.raw_data,
            template.get_fields(),
            self.max_records_per_flowset,
            |field| field.field_length,
            RecordBodyKind::Ipfix,
        );
        let (preflight, flowset_length, new_header_length) = match self
            .validate_ipfix_pending_replay(
                preflight,
                entry.raw_data.len(),
                current_header_length,
            ) {
            Ok(result) => result,
            Err(PendingOutputError::Invalid) => return None,
            Err(error) => return Some(error.into()),
        };
        let (mut data, padding_len) =
            match self
                .decoded_output_budget
                .materialize_pending(Some(preflight), |budget| {
                    OptionsData::parse_with_registry_and_budget(
                        &entry.raw_data,
                        &template,
                        &self.enterprise_registry,
                        self.max_records_per_flowset,
                        budget,
                    )
                }) {
                Ok(result) => result,
                Err(PendingOutputError::Invalid) => return None,
                Err(error) => return Some(error.into()),
            };
        data.padding = entry.raw_data[entry.raw_data.len() - padding_len..].to_vec();
        self.ipfix_options_templates.promote(&template_id);
        flowsets.push(Self::replayed_flowset(
            template_id,
            flowset_length,
            FlowSetBody::OptionsData(data),
        ));
        Some(IpfixPendingReplayOutcome::Replayed { new_header_length })
    }

    fn try_replay_embedded_v9_data(
        &mut self,
        flowsets: &mut Vec<FlowSet>,
        template_id: u16,
        entry: &PendingFlowEntry,
        current_header_length: u16,
    ) -> Option<IpfixPendingReplayOutcome> {
        let template = crate::variable_versions::peek_valid_template(
            &mut self.v9_templates,
            &template_id,
            &self.ttl_config,
            &mut self.metrics,
        )?;
        let preflight = V9Data::decoded_output_preflight(
            &entry.raw_data,
            &template,
            self.max_records_per_flowset,
            RecordBodyKind::Ipfix,
        );
        let (preflight, flowset_length, new_header_length) = match self
            .validate_ipfix_pending_replay(
                preflight,
                entry.raw_data.len(),
                current_header_length,
            ) {
            Ok(result) => result,
            Err(PendingOutputError::Invalid) => return None,
            Err(error) => return Some(error.into()),
        };
        let (mut data, padding_len) =
            match self
                .decoded_output_budget
                .materialize_pending(Some(preflight), |budget| {
                    V9Data::parse_with_budget(
                        &entry.raw_data,
                        &template,
                        self.max_records_per_flowset,
                        budget,
                    )
                }) {
                Ok(result) => result,
                Err(PendingOutputError::Invalid) => return None,
                Err(error) => return Some(error.into()),
            };
        data.padding = entry.raw_data[entry.raw_data.len() - padding_len..].to_vec();
        self.v9_templates.promote(&template_id);
        flowsets.push(Self::replayed_flowset(
            template_id,
            flowset_length,
            FlowSetBody::V9Data(data),
        ));
        Some(IpfixPendingReplayOutcome::Replayed { new_header_length })
    }

    fn try_replay_embedded_v9_options_data(
        &mut self,
        flowsets: &mut Vec<FlowSet>,
        template_id: u16,
        entry: &PendingFlowEntry,
        current_header_length: u16,
    ) -> Option<IpfixPendingReplayOutcome> {
        let template = crate::variable_versions::peek_valid_template(
            &mut self.v9_options_templates,
            &template_id,
            &self.ttl_config,
            &mut self.metrics,
        )?;
        let preflight = V9OptionsData::decoded_output_preflight(
            &entry.raw_data,
            &template,
            self.max_records_per_flowset,
            RecordBodyKind::Ipfix,
        );
        let (preflight, flowset_length, new_header_length) = match self
            .validate_ipfix_pending_replay(
                preflight,
                entry.raw_data.len(),
                current_header_length,
            ) {
            Ok(result) => result,
            Err(PendingOutputError::Invalid) => return None,
            Err(error) => return Some(error.into()),
        };
        let data =
            match self
                .decoded_output_budget
                .materialize_pending(Some(preflight), |budget| {
                    V9OptionsData::parse_with_budget(
                        &entry.raw_data,
                        &template,
                        self.max_records_per_flowset,
                        budget,
                    )
                }) {
                Ok((data, _)) => data,
                Err(PendingOutputError::Invalid) => return None,
                Err(error) => return Some(error.into()),
            };
        self.v9_options_templates.promote(&template_id);
        flowsets.push(Self::replayed_flowset(
            template_id,
            flowset_length,
            FlowSetBody::V9OptionsData(data),
        ));
        Some(IpfixPendingReplayOutcome::Replayed { new_header_length })
    }

    fn validate_ipfix_pending_replay(
        &self,
        preflight: Option<PendingOutputPreflight>,
        body_length: usize,
        current_header_length: u16,
    ) -> Result<(PendingOutputPreflight, u16, u16), PendingOutputError> {
        let preflight = self
            .decoded_output_budget
            .validate_pending_full_budget(preflight)?;
        let flowset_length = body_length
            .checked_add(4)
            .and_then(|length| u16::try_from(length).ok())
            .ok_or(PendingOutputError::NeverFits)?;

        // A store-backed parser can restore a template from an empty Data Set
        // (16-byte message header plus 4-byte Set header). Without a store,
        // replay requires a valid one-field Template Set, which needs 28 bytes.
        let minimum_trigger_length = if self.template_store.is_some() {
            MIN_STORE_REPLAY_TRIGGER_MESSAGE_LENGTH
        } else {
            MIN_TEMPLATE_REPLAY_TRIGGER_MESSAGE_LENGTH
        };
        if minimum_trigger_length.checked_add(flowset_length).is_none() {
            return Err(PendingOutputError::NeverFits);
        }

        self.decoded_output_budget
            .validate_pending_remaining(preflight)?;
        let new_header_length = current_header_length
            .checked_add(flowset_length)
            .ok_or(PendingOutputError::TemporarilyDoesNotFit)?;
        Ok((preflight, flowset_length, new_header_length))
    }

    fn replayed_flowset(template_id: u16, flowset_length: u16, body: FlowSetBody) -> FlowSet {
        FlowSet {
            header: FlowSetHeader {
                header_id: template_id,
                length: flowset_length,
            },
            body,
        }
    }

    /// Returns a sorted, deduplicated list of all available template IDs.
    pub fn available_template_ids(&self) -> Vec<u16> {
        let mut ids: Vec<u16> = self
            .templates
            .iter()
            .map(|(&id, _)| id)
            .chain(self.v9_templates.iter().map(|(&id, _)| id))
            .chain(self.ipfix_options_templates.iter().map(|(&id, _)| id))
            .chain(self.v9_options_templates.iter().map(|(&id, _)| id))
            .collect();
        ids.sort_unstable();
        ids.dedup();
        ids
    }
}

// ---------------------------------------------------------------------------
// Parsing impl blocks (moved from mod.rs)
// ---------------------------------------------------------------------------

/// Trait abstracting the template ID and field count accessors needed by the
/// generic insertion helper and template withdrawal detection.
trait HasTemplateId: Clone + PartialEq {
    fn template_id(&self) -> u16;
    /// Returns the declared field count. A field count of 0 signals template
    /// withdrawal per RFC 7011 Section 3.4.3.
    fn field_count(&self) -> u16;
}

impl HasTemplateId for Template {
    fn template_id(&self) -> u16 {
        self.template_id
    }
    fn field_count(&self) -> u16 {
        self.field_count
    }
}

impl HasTemplateId for OptionsTemplate {
    fn template_id(&self) -> u16 {
        self.template_id
    }
    fn field_count(&self) -> u16 {
        self.field_count
    }
}

impl HasTemplateId for V9Template {
    fn template_id(&self) -> u16 {
        self.template_id
    }
    fn field_count(&self) -> u16 {
        self.field_count
    }
}

impl HasTemplateId for V9OptionsTemplate {
    fn template_id(&self) -> u16 {
        self.template_id
    }
    fn field_count(&self) -> u16 {
        // V9 options templates don't support withdrawal
        // Return combined field count (non-zero for valid templates)
        let scope = self.options_scope_length / 4;
        let option = self.options_length / 4;
        scope.saturating_add(option)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IpfixTemplateSlot {
    IpfixData,
    IpfixOptions,
    V9Data,
    V9Options,
}

impl IpfixTemplateSlot {
    const ALL: [Self; 4] = [
        Self::IpfixData,
        Self::IpfixOptions,
        Self::V9Data,
        Self::V9Options,
    ];

    fn store_kind(self) -> TemplateKind {
        match self {
            Self::IpfixData => TemplateKind::IpfixData,
            Self::IpfixOptions => TemplateKind::IpfixOptions,
            Self::V9Data => TemplateKind::IpfixV9Data,
            Self::V9Options => TemplateKind::IpfixV9Options,
        }
    }
}

/// Remove one physical cache entry and report whether it was still a live owner.
fn remove_cached_owner<T>(
    cache: &mut LazyLruCache<u16, TemplateWithTtl<Arc<T>>>,
    template_id: u16,
    ttl_config: &Option<TtlConfig>,
    metrics: &mut CacheMetricsInner,
) -> bool {
    let Some(expired) = cache
        .peek(&template_id)
        .map(|entry| ttl_config.as_ref().is_some_and(|ttl| entry.is_expired(ttl)))
    else {
        return false;
    };

    cache.pop(&template_id);
    if expired {
        metrics.record_expiration();
        false
    } else {
        true
    }
}

/// Insert one template and return any different Template ID evicted by the LRU.
fn insert_template<T: HasTemplateId>(
    cache: &mut LazyLruCache<u16, TemplateWithTtl<Arc<T>>>,
    template: &T,
    ttl_enabled: bool,
    metrics: &mut CacheMetricsInner,
) -> Option<u16> {
    let template_id = template.template_id();
    if let Some(existing) = cache.peek(&template_id)
        && existing.template.as_ref() != template
    {
        metrics.record_collision();
    }

    let wrapped = TemplateWithTtl::new(Arc::new(template.clone()), ttl_enabled);
    let evicted_id = cache
        .push(template_id, wrapped)
        .and_then(|(evicted_id, _)| (evicted_id != template_id).then_some(evicted_id));
    if evicted_id.is_some() {
        metrics.record_eviction();
    }
    metrics.record_insertion();
    evicted_id
}

impl IPFixParser {
    /// Remove every physical owner except the slot receiving the new definition.
    fn remove_other_template_owners(
        &mut self,
        installed_slot: IpfixTemplateSlot,
        template_id: u16,
    ) {
        let mut replaced_live_owner = false;
        if installed_slot != IpfixTemplateSlot::IpfixData {
            replaced_live_owner |= remove_cached_owner(
                &mut self.templates,
                template_id,
                &self.ttl_config,
                &mut self.metrics,
            );
        }
        if installed_slot != IpfixTemplateSlot::IpfixOptions {
            replaced_live_owner |= remove_cached_owner(
                &mut self.ipfix_options_templates,
                template_id,
                &self.ttl_config,
                &mut self.metrics,
            );
        }
        if installed_slot != IpfixTemplateSlot::V9Data {
            replaced_live_owner |= remove_cached_owner(
                &mut self.v9_templates,
                template_id,
                &self.ttl_config,
                &mut self.metrics,
            );
        }
        if installed_slot != IpfixTemplateSlot::V9Options {
            replaced_live_owner |= remove_cached_owner(
                &mut self.v9_options_templates,
                template_id,
                &self.ttl_config,
                &mut self.metrics,
            );
        }
        if replaced_live_owner {
            self.metrics.record_collision();
        }

        if self.template_store.is_some() {
            for slot in IpfixTemplateSlot::ALL {
                if slot != installed_slot {
                    self.evict_from_store(slot.store_kind(), template_id);
                }
            }
        }
    }

    /// Add templates to the parser by cloning from slice.
    fn add_ipfix_templates(&mut self, templates: &[Template]) {
        let ttl_enabled = self.ttl_config.is_some();
        for template in templates {
            self.remove_other_template_owners(
                IpfixTemplateSlot::IpfixData,
                template.template_id,
            );
            let evicted = insert_template(
                &mut self.templates,
                template,
                ttl_enabled,
                &mut self.metrics,
            );
            if self.template_store.is_some() {
                self.put_to_store(
                    TemplateKind::IpfixData,
                    template.template_id,
                    encode_ipfix_template(template),
                );
                if let Some(id) = evicted {
                    self.evict_from_store(TemplateKind::IpfixData, id);
                }
            }
        }
    }

    fn add_ipfix_options_templates(&mut self, templates: &[OptionsTemplate]) {
        let ttl_enabled = self.ttl_config.is_some();
        for template in templates {
            self.remove_other_template_owners(
                IpfixTemplateSlot::IpfixOptions,
                template.template_id,
            );
            let evicted = insert_template(
                &mut self.ipfix_options_templates,
                template,
                ttl_enabled,
                &mut self.metrics,
            );
            if self.template_store.is_some() {
                self.put_to_store(
                    TemplateKind::IpfixOptions,
                    template.template_id,
                    encode_ipfix_options_template(template),
                );
                if let Some(id) = evicted {
                    self.evict_from_store(TemplateKind::IpfixOptions, id);
                }
            }
        }
    }

    fn add_v9_templates(&mut self, templates: &[V9Template]) {
        let ttl_enabled = self.ttl_config.is_some();
        for template in templates {
            self.remove_other_template_owners(IpfixTemplateSlot::V9Data, template.template_id);
            let evicted = insert_template(
                &mut self.v9_templates,
                template,
                ttl_enabled,
                &mut self.metrics,
            );
            if self.template_store.is_some() {
                self.put_to_store(
                    TemplateKind::IpfixV9Data,
                    template.template_id,
                    encode_v9_template(template),
                );
                if let Some(id) = evicted {
                    self.evict_from_store(TemplateKind::IpfixV9Data, id);
                }
            }
        }
    }

    fn add_v9_options_templates(&mut self, templates: &[V9OptionsTemplate]) {
        let ttl_enabled = self.ttl_config.is_some();
        for template in templates {
            self.remove_other_template_owners(
                IpfixTemplateSlot::V9Options,
                template.template_id,
            );
            let evicted = insert_template(
                &mut self.v9_options_templates,
                template,
                ttl_enabled,
                &mut self.metrics,
            );
            if self.template_store.is_some() {
                self.put_to_store(
                    TemplateKind::IpfixV9Options,
                    template.template_id,
                    encode_v9_options_template(template),
                );
                if let Some(id) = evicted {
                    self.evict_from_store(TemplateKind::IpfixV9Options, id);
                }
            }
        }
    }

    fn drain_pending_template_ids(&mut self, template_ids: &[u16]) {
        let Some(cache) = self.pending_flows.as_mut() else {
            return;
        };
        for &template_id in template_ids {
            let dropped = cache.drain(template_id, &mut self.metrics).len() as u64;
            if dropped > 0 {
                self.metrics.record_pending_dropped_n(dropped);
            }
        }
    }

    fn remove_data_template_owners(&mut self, template_ids: &[u16]) {
        for &template_id in template_ids {
            self.templates.pop(&template_id);
            self.v9_templates.pop(&template_id);
            self.evict_from_store(TemplateKind::IpfixData, template_id);
            self.evict_from_store(TemplateKind::IpfixV9Data, template_id);
        }
        self.drain_pending_template_ids(template_ids);
    }

    fn remove_options_template_owners(&mut self, template_ids: &[u16]) {
        for &template_id in template_ids {
            self.ipfix_options_templates.pop(&template_id);
            self.v9_options_templates.pop(&template_id);
            self.evict_from_store(TemplateKind::IpfixOptions, template_id);
            self.evict_from_store(TemplateKind::IpfixV9Options, template_id);
        }
        self.drain_pending_template_ids(template_ids);
    }

    /// Remove an IPFIX template by ID (RFC 7011 Section 8.1 template withdrawal).
    /// Also purges any pending flows cached under this template ID to prevent
    /// stale data from being replayed against a replacement template.
    ///
    /// Per RFC 7011 §8.1, template_id == DATA_TEMPLATE_IPFIX_ID (2) with
    /// field_count == 0 signals "withdraw ALL data templates". This method
    /// handles both individual and bulk withdrawal.
    fn withdraw_ipfix_template(&mut self, template_id: u16) {
        if template_id == DATA_TEMPLATE_IPFIX_ID {
            let mut ids: Vec<u16> = self.templates.iter().map(|(&id, _)| id).collect();
            ids.extend(self.v9_templates.iter().map(|(&id, _)| id));
            ids.sort_unstable();
            ids.dedup();
            self.remove_data_template_owners(&ids);
        } else {
            self.remove_data_template_owners(&[template_id]);
        }
    }

    /// Remove an IPFIX options template by ID (template withdrawal).
    /// Also purges any pending flows cached under this template ID.
    ///
    /// Per RFC 7011 §8.1, template_id == OPTIONS_TEMPLATE_IPFIX_ID (3) with
    /// field_count == 0 signals "withdraw ALL options templates".
    fn withdraw_ipfix_options_template(&mut self, template_id: u16) {
        if template_id == OPTIONS_TEMPLATE_IPFIX_ID {
            let mut ids: Vec<u16> = self
                .ipfix_options_templates
                .iter()
                .map(|(&id, _)| id)
                .collect();
            ids.extend(self.v9_options_templates.iter().map(|(&id, _)| id));
            ids.sort_unstable();
            ids.dedup();
            self.remove_options_template_owners(&ids);
        } else {
            self.remove_options_template_owners(&[template_id]);
        }
    }
}

impl FlowSetBody {
    #[allow(clippy::too_many_arguments)]
    fn parse_templates<'a, T, F>(
        i: &'a [u8],
        parser: &mut IPFixParser,
        parse_fn: F,
        single_variant: fn(T) -> FlowSetBody,
        multi_variant: fn(Vec<T>) -> FlowSetBody,
        validate: fn(&T, &IPFixParser) -> bool,
        add_templates: fn(&mut IPFixParser, &[T]),
        withdraw_template: Option<fn(&mut IPFixParser, u16)>,
    ) -> IResult<&'a [u8], FlowSetBody>
    where
        T: Clone + HasTemplateId,
        F: Fn(&'a [u8]) -> IResult<&'a [u8], T>,
    {
        let (i, templates) = many0(complete(parse_fn))(i)?;

        // Handle template withdrawals (RFC 7011 Section 8.1):
        // Templates with field_count=0 signal withdrawal from the cache.
        // Skip withdrawal for IDs that also have a new definition in the
        // same flowset — the new definition will simply replace the old one
        // without needlessly draining pending flows.
        let mut had_withdrawals = false;
        if let Some(withdraw_fn) = withdraw_template {
            for t in &templates {
                if t.field_count() == 0 {
                    let id = t.template_id();
                    // "Withdraw all" IDs (2 for data, 3 for options) always
                    // take effect regardless of other templates in the batch.
                    let has_redefinition = id != DATA_TEMPLATE_IPFIX_ID
                        && id != OPTIONS_TEMPLATE_IPFIX_ID
                        && templates
                            .iter()
                            .any(|other| other.template_id() == id && other.field_count() > 0);
                    if !has_redefinition {
                        withdraw_fn(parser, id);
                    }
                    had_withdrawals = true;
                }
            }
        }

        // Filter to only valid templates (withdrawals will be filtered out
        // since they have empty fields, failing the is_valid check)
        let valid_templates: Vec<_> = templates
            .into_iter()
            .filter(|t| validate(t, parser))
            .collect();
        if valid_templates.is_empty() {
            // If we processed withdrawals, return Empty instead of error
            if had_withdrawals {
                return Ok((i, FlowSetBody::Empty));
            }
            return Err(nom::Err::Error(nom::error::Error::new(
                i,
                nom::error::ErrorKind::Verify,
            )));
        }
        // Pass slice to add_templates to clone only what's needed
        add_templates(parser, &valid_templates);
        match valid_templates.len() {
            1 => {
                if let Some(template) = valid_templates.into_iter().next() {
                    Ok((i, single_variant(template)))
                } else {
                    Err(nom::Err::Error(nom::error::Error::new(
                        i,
                        nom::error::ErrorKind::Verify,
                    )))
                }
            }
            _ => Ok((i, multi_variant(valid_templates))),
        }
    }

    pub(super) fn parse<'a>(
        i: &'a [u8],
        parser: &mut IPFixParser,
        id: u16,
    ) -> IResult<&'a [u8], FlowSetBody> {
        match id {
            DATA_TEMPLATE_IPFIX_ID => Self::parse_templates(
                i,
                parser,
                Template::parse,
                FlowSetBody::Template,
                FlowSetBody::Templates,
                |t: &Template, p: &IPFixParser| t.is_valid(p),
                |parser, templates| parser.add_ipfix_templates(templates),
                Some(|parser: &mut IPFixParser, id| parser.withdraw_ipfix_template(id)),
            ),
            DATA_TEMPLATE_V9_ID => Self::parse_templates(
                i,
                parser,
                V9Template::parse,
                FlowSetBody::V9Template,
                FlowSetBody::V9Templates,
                |t: &V9Template, p: &IPFixParser| {
                    // Validate V9 templates using IPFIX parser limits.
                    // V9 does not support variable-length fields. Individual
                    // zero-length fields are safe when the complete record has
                    // a nonzero size.
                    usize::from(t.field_count) <= p.max_field_count
                        && !t.fields.is_empty()
                        && t.fields.iter().all(|f| f.field_length != 65535)
                        && t.get_total_size() > 0
                        && usize::from(t.get_total_size()) <= p.max_template_total_size
                },
                |parser, templates| parser.add_v9_templates(templates),
                None, // V9 doesn't support template withdrawal
            ),
            OPTIONS_TEMPLATE_V9_ID => Self::parse_templates(
                i,
                parser,
                V9OptionsTemplate::parse,
                FlowSetBody::V9OptionsTemplate,
                FlowSetBody::V9OptionsTemplates,
                |t: &V9OptionsTemplate, p: &IPFixParser| {
                    let scope_count = usize::from(t.options_scope_length / 4);
                    let option_count = usize::from(t.options_length / 4);
                    t.options_scope_length.is_multiple_of(4)
                        && t.options_length.is_multiple_of(4)
                        && scope_count > 0
                        && scope_count <= p.max_field_count
                        && option_count <= p.max_field_count
                        && scope_count.saturating_add(option_count) <= p.max_field_count
                        && t.get_total_size() > 0
                        && usize::from(t.get_total_size()) <= p.max_template_total_size
                        // V9 does not support the IPFIX variable-length sentinel.
                        && t.scope_fields.iter().all(|f| f.field_length != 65535)
                        && t.option_fields.iter().all(|f| f.field_length != 65535)
                },
                |parser, templates| parser.add_v9_options_templates(templates),
                None, // V9 doesn't support template withdrawal
            ),
            OPTIONS_TEMPLATE_IPFIX_ID => Self::parse_templates(
                i,
                parser,
                OptionsTemplate::parse,
                FlowSetBody::OptionsTemplate,
                FlowSetBody::OptionsTemplates,
                |t: &OptionsTemplate, p: &IPFixParser| t.is_valid(p),
                |parser, templates| parser.add_ipfix_options_templates(templates),
                Some(|parser: &mut IPFixParser, id| parser.withdraw_ipfix_options_template(id)),
            ),
            // Parse Data
            _ => {
                // Definition installation keeps these physical caches disjoint by
                // Template ID, so this probe order selects representation rather
                // than resolving competing owners.

                // Try IPFix templates
                if let Some(template) = crate::variable_versions::get_valid_template(
                    &mut parser.templates,
                    &id,
                    &parser.ttl_config,
                    &mut parser.metrics,
                ) {
                    parser.metrics.record_hit();
                    if template.get_fields().is_empty() {
                        return Ok((i, FlowSetBody::Empty));
                    }
                    let (i, data) = Data::parse_with_registry_and_budget(
                        i,
                        &template,
                        &parser.enterprise_registry,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::Data(data)));
                }

                // Try IPFix options templates
                if let Some(template) = crate::variable_versions::get_valid_template(
                    &mut parser.ipfix_options_templates,
                    &id,
                    &parser.ttl_config,
                    &mut parser.metrics,
                ) {
                    parser.metrics.record_hit();
                    if template.get_fields().is_empty() {
                        return Ok((i, FlowSetBody::Empty));
                    }
                    let (i, data) = OptionsData::parse_with_registry_and_budget(
                        i,
                        &template,
                        &parser.enterprise_registry,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::OptionsData(data)));
                }

                // Try V9 templates
                if let Some(template) = crate::variable_versions::get_valid_template(
                    &mut parser.v9_templates,
                    &id,
                    &parser.ttl_config,
                    &mut parser.metrics,
                ) {
                    parser.metrics.record_hit();
                    let (i, data) = V9Data::parse_with_budget(
                        i,
                        &template,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::V9Data(data)));
                }

                // Try V9 options templates
                if let Some(template) = crate::variable_versions::get_valid_template(
                    &mut parser.v9_options_templates,
                    &id,
                    &parser.ttl_config,
                    &mut parser.metrics,
                ) {
                    parser.metrics.record_hit();
                    let (i, data) = V9OptionsData::parse_with_budget(
                        i,
                        &template,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::V9OptionsData(data)));
                }

                // Read-through: consult the secondary template store before
                // declaring a miss. Probe in the same order as the in-process
                // caches above so that priority is preserved when the same
                // template ID exists under multiple kinds. Each fetch helper
                // also pushes the decoded template into the in-process LRU
                // so subsequent flowsets are served from the hot path.
                if let Some(template) = parser.fetch_ipfix_template_from_store(id) {
                    parser.metrics.record_hit();
                    if template.get_fields().is_empty() {
                        return Ok((i, FlowSetBody::Empty));
                    }
                    let (i, data) = Data::parse_with_registry_and_budget(
                        i,
                        &template,
                        &parser.enterprise_registry,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::Data(data)));
                }
                if let Some(template) = parser.fetch_ipfix_options_template_from_store(id) {
                    parser.metrics.record_hit();
                    if template.get_fields().is_empty() {
                        return Ok((i, FlowSetBody::Empty));
                    }
                    let (i, data) = OptionsData::parse_with_registry_and_budget(
                        i,
                        &template,
                        &parser.enterprise_registry,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::OptionsData(data)));
                }
                if let Some(template) = parser.fetch_v9_template_from_store(id) {
                    parser.metrics.record_hit();
                    let (i, data) = V9Data::parse_with_budget(
                        i,
                        &template,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::V9Data(data)));
                }
                if let Some(template) = parser.fetch_v9_options_template_from_store(id) {
                    parser.metrics.record_hit();
                    let (i, data) = V9OptionsData::parse_with_budget(
                        i,
                        &template,
                        parser.max_records_per_flowset,
                        &mut parser.decoded_output_budget,
                    )?;
                    return Ok((i, FlowSetBody::V9OptionsData(data)));
                }

                // Template not found or expired — one miss per flowset,
                // symmetric with one hit per flowset above.
                parser.metrics.record_miss();
                if id > 255 {
                    // Store full raw data only when the pending cache is
                    // enabled, the entry fits the size limit, AND the
                    // per-template cap has room.  Otherwise truncate to
                    // max_error_sample_size to avoid large allocations
                    // that would be immediately rejected.
                    let (raw_data, truncated) = if parser
                        .pending_flows
                        .as_ref()
                        .is_some_and(|c| c.would_accept(id, i.len()))
                    {
                        (i.to_vec(), false)
                    } else {
                        let limit = i.len().min(parser.max_error_sample_size);
                        (i[..limit].to_vec(), limit < i.len())
                    };
                    let info = NoTemplateInfo {
                        template_id: id,
                        raw_data,
                        truncated,
                    };
                    Ok((&[] as &[u8], FlowSetBody::NoTemplate(info)))
                } else {
                    // Set IDs 4-255 are reserved per RFC 7011; skip gracefully
                    Ok((&[] as &[u8], FlowSetBody::Empty))
                }
            }
        }
    }
}

impl Template {
    /// Validate the template against parser configuration
    pub fn is_valid(&self, parser: &IPFixParser) -> bool {
        <Self as CommonTemplate>::is_valid(self, parser)
    }
}

impl OptionsTemplate {
    /// Validate the options template against parser configuration
    pub fn is_valid(&self, parser: &IPFixParser) -> bool {
        <Self as CommonTemplate>::is_valid(self, parser)
    }
}

/// Collect template field lengths only when at least one field is variable-length.
fn collect_varlen_field_lengths(fields: &[TemplateField]) -> Vec<u16> {
    if fields.iter().any(|f| f.field_length == 65535) {
        fields.iter().map(|f| f.field_length).collect()
    } else {
        Vec::new()
    }
}

impl Data {
    pub(super) fn parse_with_registry_and_budget<'a>(
        i: &'a [u8],
        template: &Template,
        registry: &EnterpriseFieldRegistry,
        max_records: usize,
        budget: &mut DecodedOutputBudget,
    ) -> IResult<&'a [u8], Self> {
        let template_field_lengths = collect_varlen_field_lengths(template.get_fields());
        let (i, fields) = FieldParser::parse_with_registry_and_budget(
            i,
            template,
            registry,
            max_records,
            budget,
        )?;
        Ok((
            i,
            Self {
                fields,
                padding: vec![],
                template_field_lengths,
            },
        ))
    }

    /// Parse one data body with explicit finite output limits.
    pub fn parse_with_limits<'a>(
        i: &'a [u8],
        template: &Template,
        limits: crate::DecodedOutputLimits,
    ) -> IResult<&'a [u8], Self> {
        let template_field_lengths = collect_varlen_field_lengths(template.get_fields());
        let mut budget = limits.budget();
        let (i, fields) =
            FieldParser::parse_with_budget(i, template, limits.max_records(), &mut budget)?;
        Ok((
            i,
            Self {
                fields,
                padding: vec![],
                template_field_lengths,
            },
        ))
    }
}

impl OptionsData {
    pub(super) fn parse_with_registry_and_budget<'a>(
        i: &'a [u8],
        template: &OptionsTemplate,
        registry: &EnterpriseFieldRegistry,
        max_records: usize,
        budget: &mut DecodedOutputBudget,
    ) -> IResult<&'a [u8], Self> {
        let template_field_lengths = collect_varlen_field_lengths(template.get_fields());
        let (i, fields) = FieldParser::parse_with_registry_and_budget(
            i,
            template,
            registry,
            max_records,
            budget,
        )?;
        Ok((
            i,
            Self {
                fields,
                padding: vec![],
                template_field_lengths,
            },
        ))
    }

    /// Parse one options-data body with explicit finite output limits.
    pub fn parse_with_limits<'a>(
        i: &'a [u8],
        template: &OptionsTemplate,
        limits: crate::DecodedOutputLimits,
    ) -> IResult<&'a [u8], Self> {
        let template_field_lengths = collect_varlen_field_lengths(template.get_fields());
        let mut budget = limits.budget();
        let (i, fields) =
            FieldParser::parse_with_budget(i, template, limits.max_records(), &mut budget)?;
        Ok((
            i,
            Self {
                fields,
                padding: vec![],
                template_field_lengths,
            },
        ))
    }
}

impl<'a> FieldParser {
    /// Core parsing loop shared by `parse` and `parse_with_registry`.
    ///
    /// The `parse_field` closure controls how each template field is decoded —
    /// either using built-in field types or the enterprise registry.
    fn parse_inner<T: CommonTemplate, F>(
        mut i: &'a [u8],
        template: &T,
        max_records: usize,
        budget: &mut DecodedOutputBudget,
        parse_field: F,
    ) -> IResult<&'a [u8], Vec<Vec<IPFixFieldPair>>>
    where
        F: Fn(&TemplateField, &'a [u8]) -> IResult<&'a [u8], FieldValue>,
    {
        let template_fields = template.get_fields();
        if template_fields.is_empty() {
            return Ok((i, Vec::new()));
        }

        // Estimate capacity based on input size and template field count.
        // Variable-length fields (field_length == 65535) are RFC 7011 markers,
        // not actual sizes — count them as 1 byte minimum for estimation.
        let template_size: usize = template_fields
            .iter()
            .map(|f| {
                if f.field_length == 65535 {
                    1
                } else {
                    usize::from(f.field_length)
                }
            })
            .sum();
        if template_size == 0 {
            return Err(nom::Err::Error(nom::error::Error::new(
                i,
                nom::error::ErrorKind::Verify,
            )));
        }
        let field_count = template_fields.len();
        let all_fixed = template_fields
            .iter()
            .all(|field| field.field_length != u16::MAX);
        let fixed_payload_per_record = all_fixed.then_some(template_size);
        let (remaining_values, remaining_payload) = budget.remaining();
        let mut estimated_records = (i.len() / template_size)
            .min(max_records)
            .min(remaining_values / field_count);
        if let Some(payload_per_record) = fixed_payload_per_record {
            estimated_records = estimated_records.min(remaining_payload / payload_per_record);
        }
        let mut res = Vec::with_capacity(estimated_records);

        // Try to parse as much as we can, but if it fails, just return what we have so far.
        while !i.is_empty() && res.len() < max_records {
            if let Some(payload_per_record) = fixed_payload_per_record
                && i.len() < payload_per_record
            {
                break;
            }
            let before = i;
            let checkpoint = budget.checkpoint();
            let record_payload = if let Some(payload_per_record) = fixed_payload_per_record {
                payload_per_record
            } else {
                let Some((_, payload)) =
                    crate::variable_versions::output_budget::scan_variable_record(
                        i,
                        template_fields,
                        |field| field.field_length,
                    )
                else {
                    break;
                };
                payload
            };
            if budget.reserve(field_count, record_payload).is_err() {
                return Err(nom::Err::Error(nom::error::Error::new(
                    i,
                    nom::error::ErrorKind::TooLarge,
                )));
            }
            let mut vec = Vec::with_capacity(field_count);
            for field in template_fields.iter() {
                match parse_field(field, i) {
                    Ok((remaining, field_value)) => {
                        vec.push((field.field_type, field_value));
                        i = remaining;
                    }
                    Err(_) => {
                        budget.rollback(checkpoint);
                        i = before;
                        return Ok((i, res));
                    }
                }
            }
            // Guard against infinite loops: if no bytes were consumed after
            // parsing a full record, stop to prevent CPU-bound DoS.
            if std::ptr::eq(i, before) {
                budget.rollback(checkpoint);
                break;
            }
            res.push(vec);
        }
        Ok((i, res))
    }

    /// Takes a byte stream and a cached template.
    /// Fields get matched to static types.
    /// Returns BTree of IPFix Types & Fields or IResult Error.
    pub(super) fn parse<T: CommonTemplate>(
        i: &'a [u8],
        template: &T,
        max_records: usize,
    ) -> IResult<&'a [u8], Vec<Vec<IPFixFieldPair>>> {
        let mut budget = DecodedOutputBudget::new(
            crate::DEFAULT_MAX_DECODED_FIELD_VALUES_PER_MESSAGE,
            crate::DEFAULT_MAX_DECODED_FIELD_PAYLOAD_BYTES_PER_MESSAGE,
        );
        Self::parse_inner(i, template, max_records, &mut budget, |field, input| {
            field.parse_as_field_value(input)
        })
    }

    fn parse_with_budget<T: CommonTemplate>(
        i: &'a [u8],
        template: &T,
        max_records: usize,
        budget: &mut DecodedOutputBudget,
    ) -> IResult<&'a [u8], Vec<Vec<IPFixFieldPair>>> {
        Self::parse_inner(i, template, max_records, budget, |field, input| {
            field.parse_as_field_value(input)
        })
    }

    fn parse_with_registry_and_budget<T: CommonTemplate>(
        i: &'a [u8],
        template: &T,
        registry: &EnterpriseFieldRegistry,
        max_records: usize,
        budget: &mut DecodedOutputBudget,
    ) -> IResult<&'a [u8], Vec<Vec<IPFixFieldPair>>> {
        Self::parse_inner(i, template, max_records, budget, |field, input| {
            field.parse_as_field_value_with_registry(input, registry)
        })
    }
}

impl TemplateField {
    // If 65535, read 1 byte.
    // If that byte is < 255 that is the length.
    // If that byte is == 255 then read 2 bytes.  That is the length.
    // Otherwise, return the field length.
    fn parse_field_length<'a>(&self, i: &'a [u8]) -> IResult<&'a [u8], u16> {
        match self.field_length {
            65535 => {
                let (i, length) = parse_u8(i)?;
                if length == 255 {
                    let (i, full_length) = parse_u16_be(i)?;
                    // RFC 7011 Section 7: length values of 0 are not permitted
                    if full_length == 0 {
                        return Err(nom::Err::Error(nom::error::Error::new(
                            i,
                            nom::error::ErrorKind::Verify,
                        )));
                    }
                    // Validate length doesn't exceed remaining buffer
                    if (full_length as usize) > i.len() {
                        return Err(nom::Err::Error(nom::error::Error::new(
                            i,
                            nom::error::ErrorKind::Eof,
                        )));
                    }
                    Ok((i, full_length))
                } else {
                    // RFC 7011 Section 7: length values of 0 are not permitted
                    if length == 0 {
                        return Err(nom::Err::Error(nom::error::Error::new(
                            i,
                            nom::error::ErrorKind::Verify,
                        )));
                    }
                    // Validate length doesn't exceed remaining buffer
                    if (length as usize) > i.len() {
                        return Err(nom::Err::Error(nom::error::Error::new(
                            i,
                            nom::error::ErrorKind::Eof,
                        )));
                    }
                    Ok((i, u16::from(length)))
                }
            }
            length => Ok((i, length)),
        }
    }

    fn parse_as_field_value<'a>(&self, i: &'a [u8]) -> IResult<&'a [u8], FieldValue> {
        let (i, length) = self.parse_field_length(i)?;
        FieldValue::from_field_type(i, self.field_type.into(), length)
    }

    fn parse_as_field_value_with_registry<'a>(
        &self,
        i: &'a [u8],
        registry: &EnterpriseFieldRegistry,
    ) -> IResult<&'a [u8], FieldValue> {
        let (i, length) = self.parse_field_length(i)?;
        let field_type = self.field_type.to_field_data_type(registry);
        FieldValue::from_field_type(i, field_type, length)
    }
}
