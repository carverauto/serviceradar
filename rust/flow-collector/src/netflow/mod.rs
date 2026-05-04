pub mod converter;

use crate::config::PendingFlowsCacheConfig;
use crate::flowpb::FlowMessage;
use crate::listener::{FlowHandler, filter_and_track_flows, get_current_time_ns};
use crate::metrics::ListenerMetrics;
use converter::Converter;
use log::{debug, info, warn};
use netflow_parser::{
    AutoScopedParser, IpfixSourceKey, NetflowParserBuilder, ParserCacheInfo, PendingFlowsConfig,
    TemplateEvent, TemplateStore, V9SourceKey,
};
use std::collections::HashMap;
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
    metrics: Arc<ListenerMetrics>,
}

impl NetflowHandler {
    pub fn new(
        max_templates: usize,
        pending_flows: Option<&PendingFlowsCacheConfig>,
        template_store: Option<Arc<dyn TemplateStore>>,
        metrics: Arc<ListenerMetrics>,
    ) -> Self {
        let pending_enabled = pending_flows.is_some();
        let store_enabled = template_store.is_some();
        let mut builder = NetflowParserBuilder::default()
            .with_cache_size(max_templates)
            .on_template_event(make_template_event_callback(pending_enabled));

        if let Some(pf) = pending_flows {
            let mut pf_config =
                PendingFlowsConfig::with_ttl(pf.max_pending_flows, Duration::from_secs(pf.ttl_secs));
            pf_config.max_entries_per_template = pf.max_entries_per_template;
            pf_config.max_entry_size_bytes = pf.max_entry_size_bytes;
            builder = builder.with_pending_flows(pf_config);
        }

        if let Some(store) = template_store {
            // AutoScopedParser sets the per-source scope itself
            // (e.g. "v9:1.2.3.4:2055/0"); we just hand it the store.
            builder = builder.with_template_store(store);
        }

        let parser = AutoScopedParser::try_with_builder(builder)
            .expect("failed to build netflow parser");
        let parser = Arc::new(Mutex::new(parser));

        // Spawn a background ticker that aggregates per-source CacheMetrics
        // into the listener-level Prometheus counters once a second. This
        // keeps the parse_datagram hot path free of O(sources) work and
        // (combined with retired-source accounting in the ticker) makes
        // the surfaced counters monotonically increasing — required for
        // Prometheus rate() semantics. Only spawned when a template store
        // is configured, since the counters are no-ops otherwise.
        if store_enabled {
            let parser_for_ticker = Arc::clone(&parser);
            let metrics_for_ticker = Arc::clone(&metrics);
            tokio::runtime::Handle::current().spawn(async move {
                run_metrics_ticker(parser_for_ticker, metrics_for_ticker).await;
            });
        }

        Self { parser, metrics }
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
            match parser.iter_packets_from_source(peer, buf) {
                Ok(iter) => iter.collect(),
                Err(e) => {
                    warn!("Failed to parse NetFlow packet from {}: {:?}", peer, e);
                    self.metrics.parse_errors.fetch_add(1, Ordering::Relaxed);
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

/// Per-source `template_store_*` snapshot used by the metrics ticker to
/// detect deltas between ticks (and to remember evicted sources' last
/// known values so the listener-level counters stay monotonic).
#[derive(Default, Clone, Copy, Debug, PartialEq, Eq)]
struct StoreCounters {
    restored: u64,
    codec_errors: u64,
    backend_errors: u64,
}

impl StoreCounters {
    /// Sum across both the V9 and IPFIX `CacheMetrics` views of a single
    /// per-source NetflowParser.
    fn from_info(info: &ParserCacheInfo) -> Self {
        Self {
            restored: info.v9.metrics.template_store_restored
                + info.ipfix.metrics.template_store_restored,
            codec_errors: info.v9.metrics.template_store_codec_errors
                + info.ipfix.metrics.template_store_codec_errors,
            backend_errors: info.v9.metrics.template_store_backend_errors
                + info.ipfix.metrics.template_store_backend_errors,
        }
    }
}

impl std::ops::AddAssign for StoreCounters {
    fn add_assign(&mut self, rhs: Self) {
        self.restored += rhs.restored;
        self.codec_errors += rhs.codec_errors;
        self.backend_errors += rhs.backend_errors;
    }
}

/// Wrapper enum so the ticker can keep a single `HashMap` keyed across
/// all three of `AutoScopedParser`'s scoping paths.
#[derive(Hash, PartialEq, Eq, Clone, Debug)]
enum SourceId {
    Ipfix(IpfixSourceKey),
    V9(V9SourceKey),
    Legacy(SocketAddr),
}

/// Mutable state carried across ticker iterations.
#[derive(Default)]
struct DeltaState {
    /// Last observed counters per still-present source. On the next tick,
    /// any `SourceId` missing from the parser's current source set is
    /// considered evicted and its last counters are folded into `retired`.
    last_known: HashMap<SourceId, StoreCounters>,
    /// Cumulative counters captured from sources that were evicted from
    /// the parser. This is what makes the listener-level total monotonic
    /// even when the parser drops sources.
    retired: StoreCounters,
}

/// Background metrics ticker — runs forever, polling the parser at 1Hz.
/// O(sources) per tick instead of per datagram. Logs a single info line
/// when started so operators can confirm it spun up.
async fn run_metrics_ticker(parser: Arc<Mutex<AutoScopedParser>>, metrics: Arc<ListenerMetrics>) {
    let mut state = DeltaState::default();
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    info!(
        "Template-store metrics ticker started for {}",
        metrics.listen_addr
    );
    loop {
        interval.tick().await;
        // Snapshot under the parser lock; release it before doing the
        // hashmap work and the atomic stores.
        let snapshot = {
            let p = parser.lock().unwrap();
            collect_snapshot(&p)
        };
        apply_snapshot(snapshot, &mut state, &metrics);
    }
}

/// Collect each per-source `StoreCounters` plus the live source count.
/// Holds the parser lock — keep this small.
fn collect_snapshot(parser: &AutoScopedParser) -> (HashMap<SourceId, StoreCounters>, u64) {
    let mut map: HashMap<SourceId, StoreCounters> = HashMap::new();
    for (key, info) in parser.ipfix_info() {
        map.insert(SourceId::Ipfix(*key), StoreCounters::from_info(&info));
    }
    for (key, info) in parser.v9_info() {
        map.insert(SourceId::V9(*key), StoreCounters::from_info(&info));
    }
    for (addr, info) in parser.legacy_info() {
        map.insert(SourceId::Legacy(*addr), StoreCounters::from_info(&info));
    }
    let count = parser.source_count() as u64;
    (map, count)
}

/// Reconcile the snapshot with the running delta state and write the
/// monotonic totals into the listener atomics.
///
/// Edge cases:
/// * Sources that disappeared between ticks have their last-observed
///   counters added to `retired` so the listener total never decreases.
/// * Sources that returned after eviction restart from a fresh parser
///   (counters at 0); their new growth accumulates *on top* of the
///   already-retired contribution from their previous lifetime.
/// * Counter increments that occur between an observation and an
///   eviction in the same tick window can be lost (we only see the
///   pre-eviction value at the next tick). Acceptable: these are rare
///   events and the loss is bounded.
fn apply_snapshot(
    snapshot: (HashMap<SourceId, StoreCounters>, u64),
    state: &mut DeltaState,
    metrics: &ListenerMetrics,
) {
    let (current, source_count) = snapshot;

    // Fold the last-known counters of evicted sources into `retired`.
    for (id, last) in &state.last_known {
        if !current.contains_key(id) {
            state.retired += *last;
        }
    }

    // Sum current and add retired to get the monotonic total.
    let mut live = StoreCounters::default();
    for v in current.values() {
        live += *v;
    }
    let total_restored = live.restored + state.retired.restored;
    let total_codec = live.codec_errors + state.retired.codec_errors;
    let total_backend = live.backend_errors + state.retired.backend_errors;

    metrics
        .template_store_restored
        .store(total_restored, Ordering::Relaxed);
    metrics
        .template_store_codec_errors
        .store(total_codec, Ordering::Relaxed);
    metrics
        .template_store_backend_errors
        .store(total_backend, Ordering::Relaxed);
    metrics.source_count.store(source_count, Ordering::Relaxed);

    state.last_known = current;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::ListenerMetrics;

    fn fake_id(n: u8) -> SourceId {
        SourceId::Legacy(format!("10.0.0.{n}:2055").parse().unwrap())
    }

    fn ctrs(r: u64, c: u64, b: u64) -> StoreCounters {
        StoreCounters {
            restored: r,
            codec_errors: c,
            backend_errors: b,
        }
    }

    fn snap(pairs: &[(SourceId, StoreCounters)], count: u64) -> (HashMap<SourceId, StoreCounters>, u64) {
        let mut m = HashMap::new();
        for (k, v) in pairs {
            m.insert(k.clone(), *v);
        }
        (m, count)
    }

    #[test]
    fn delta_state_is_monotonic_across_eviction() {
        let m = ListenerMetrics::new("netflow", "0.0.0.0:2055".into());
        let mut state = DeltaState::default();

        // Tick 1: source A has restored=10
        apply_snapshot(snap(&[(fake_id(1), ctrs(10, 0, 0))], 1), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 10);

        // Tick 2: source A grows to 15
        apply_snapshot(snap(&[(fake_id(1), ctrs(15, 0, 0))], 1), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 15);

        // Tick 3: source A is evicted — counter must NOT decrease
        apply_snapshot(snap(&[], 0), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 15);

        // Tick 4: source A reappears (fresh parser, counter starts at 0).
        // The total should be retired (15) + new live (0) = 15.
        apply_snapshot(snap(&[(fake_id(1), ctrs(0, 0, 0))], 1), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 15);

        // Tick 5: source A's new lifetime ticks up to 3.
        apply_snapshot(snap(&[(fake_id(1), ctrs(3, 0, 0))], 1), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 18);
    }

    #[test]
    fn delta_state_handles_multiple_sources_and_kinds() {
        let m = ListenerMetrics::new("netflow", "0.0.0.0:2055".into());
        let mut state = DeltaState::default();

        let a = fake_id(1);
        let b = fake_id(2);

        apply_snapshot(
            snap(&[(a.clone(), ctrs(5, 1, 0)), (b.clone(), ctrs(3, 0, 2))], 2),
            &mut state,
            &m,
        );
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 8);
        assert_eq!(m.template_store_codec_errors.load(Ordering::Relaxed), 1);
        assert_eq!(m.template_store_backend_errors.load(Ordering::Relaxed), 2);
        assert_eq!(m.source_count.load(Ordering::Relaxed), 2);

        // B evicted; A grows
        apply_snapshot(snap(&[(a, ctrs(7, 1, 0))], 1), &mut state, &m);
        assert_eq!(m.template_store_restored.load(Ordering::Relaxed), 10); // 7 + retired 3
        assert_eq!(m.template_store_codec_errors.load(Ordering::Relaxed), 1);
        assert_eq!(m.template_store_backend_errors.load(Ordering::Relaxed), 2); // 0 + retired 2
        assert_eq!(m.source_count.load(Ordering::Relaxed), 1);
    }
}
