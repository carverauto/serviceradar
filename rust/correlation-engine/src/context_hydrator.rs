//! Context hydration — the seam between data acquisition and reasoning.
//!
//! [`ContextStore`] is the trait the reasoner uses to obtain the current
//! `Context`. In V1 it is an in-process direct call; the trait preserves a
//! future hydrator/reasoner split (a gRPC/NATS implementation) without a
//! rewrite (add-causal-engine design.md, the `ContextStore` decision).

use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use dgraph_topology::{EdgeEndpoints, TopologyClient};
use srql::config::AppConfig;
use srql::{EmbeddedSrql, QueryDirection, QueryRequest};
use tokio::sync::RwLock;
use tracing::warn;

use crate::domain_model::{
    Context, Device, EdgeKind, Service, TopologyEdge,
    prune_stale_operator_rules as prune_context_operator_rules,
};
use crate::error::{CorrelationEngineError, Result};
use crate::snapshot::SnapshotStore;

/// Upper bound on rows pulled per entity in a single current-state snapshot.
const DEFAULT_MAX_HYDRATION_ROWS: i64 = 50_000;

/// The `topo.kind` values the causaloids reason over, as the engine's
/// [`EdgeKind`]. Edges are reified `TopologyEdge` nodes whose endpoints carry
/// the canonical `sr:` `device.id` (`ocsf_devices.uid`). Kinds outside this
/// table are not read (coverage broadens as new edge kinds are projected).
const TOPOLOGY_EDGE_KINDS: [(&str, EdgeKind); 7] = [
    ("CONNECTS_TO", EdgeKind::ConnectsTo),
    ("CANONICAL_TOPOLOGY", EdgeKind::ConnectsTo),
    ("LOGICAL_PEER", EdgeKind::ConnectsTo),
    ("MANAGED_BY", EdgeKind::ManagedBy),
    ("CONTAINS", EdgeKind::Contains),
    ("BACKED_BY", EdgeKind::BackedBy),
    ("DEPENDS_ON", EdgeKind::DependsOn),
];

/// Interface the reasoner uses to read the latest hydrated `Context`.
#[async_trait]
pub trait ContextStore: Send + Sync {
    /// Return the latest hydrated `Context` for a reasoning tick.
    async fn current_context(&self) -> Result<Context>;
}

/// V1 in-process hydrator.
///
/// Holds the shared `Context`: seeded by an initial `EmbeddedSrql` snapshot in
/// [`ContextHydrator::connect`], refreshed periodically by
/// [`ContextHydrator::refresh`] (reconcile + pick up new entities), and kept
/// current between refreshes by the live `signals.state.>` subscriber
/// ([`crate::subscriber`]), which applies deltas to the same shared `Context`.
///
/// TODO(1.2b+): a subscriber for the existing analytic subjects
/// (`signals.analytics.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF), and
/// broaden coverage to interfaces, agents, gateways, flows, virtualization, BGP,
/// MTR, and health transitions. Never consume TimescaleDB hypertable CDC (those
/// are queried on demand here).
pub struct ContextHydrator {
    srql: EmbeddedSrql,
    dgraph_url: Option<String>,
    ctx: Arc<RwLock<Context>>,
    snapshot: SnapshotStore,
    max_rows: i64,
}

impl ContextHydrator {
    /// Open a CNPG pool via `EmbeddedSrql` (srql `AppConfig` from `SRQL_*` /
    /// `DATABASE_URL` env), restore the on-disk snapshot, then seed the shared
    /// `Context` with an initial refresh. The initial refresh is best-effort: if
    /// CNPG is momentarily unavailable at boot, the engine serves the restored
    /// snapshot and the periodic refresh tick retries.
    pub async fn connect(snapshot_path: &str) -> Result<Self> {
        let config = AppConfig::from_env()
            .map_err(|e| CorrelationEngineError::Hydration(format!("srql config: {e}")))?;
        let dgraph_url = config.dgraph_url.clone();
        let srql = EmbeddedSrql::new(config)
            .await
            .map_err(|e| CorrelationEngineError::Hydration(format!("embedded srql: {e}")))?;

        let snapshot = SnapshotStore::new(snapshot_path);
        let restored = match snapshot.load() {
            Ok(Some(context)) => context,
            Ok(None) => Context::default(),
            Err(err) => {
                warn!(error = %err, "context snapshot load failed; starting empty");
                Context::default()
            }
        };

        let hydrator = Self {
            srql,
            dgraph_url,
            ctx: Arc::new(RwLock::new(restored)),
            snapshot,
            max_rows: DEFAULT_MAX_HYDRATION_ROWS,
        };

        if let Err(err) = hydrator.refresh().await {
            warn!(error = %err, "initial context refresh failed; serving restored snapshot");
        }

        Ok(hydrator)
    }

    /// Re-snapshot current state from CNPG, reconcile the shared `Context`, and
    /// persist it to disk. Called periodically to pick up new entities; live
    /// `signals.state.>` and `signals.analytics.>` deltas keep non-SRQL state
    /// current between refreshes.
    pub async fn refresh(&self) -> Result<()> {
        let devices = self.query("in:devices").await?;
        let services = self.query("in:services").await?;
        // Topology edges are best-effort: a Dgraph read hiccup must not abort
        // the whole refresh — the engine still reasons from the snapshot + the
        // live state-change deltas, just without the structural causaloids this
        // tick.
        let edges = match self.topology_edges().await {
            Ok(rows) => parse_topology_edges(&rows),
            Err(err) => {
                warn!(error = %err, "topology edge projection failed; reasoning without edges this tick");
                Vec::new()
            }
        };
        let devices = devices.iter().filter_map(map_device).collect();
        let services = services.iter().filter_map(map_service).collect();
        let context = {
            let mut guard = self.ctx.write().await;

            reconcile_hydrated_context(&mut guard, devices, services, edges);
            guard.clone()
        };

        if let Err(err) = self.snapshot.save(&context) {
            warn!(error = %err, "context snapshot save failed");
        }
        Ok(())
    }

    /// A handle to the shared `Context` for the live state-change subscriber.
    pub fn shared_context(&self) -> Arc<RwLock<Context>> {
        Arc::clone(&self.ctx)
    }

    /// Prune stale live operator-rule evidence from the shared context.
    pub async fn prune_stale_operator_rules(&self, now_unix_ms: i64, ttl_ms: i64) -> usize {
        let mut guard = self.ctx.write().await;
        let pruned = prune_context_operator_rules(&mut guard, now_unix_ms, ttl_ms);

        if pruned > 0
            && let Err(err) = self.snapshot.save(&guard)
        {
            warn!(error = %err, "context snapshot save failed after operator-rule pruning");
        }

        pruned
    }

    /// Read the topology edges of every reasoned-over kind from Dgraph. The
    /// read is paged: the edge set grows with the fleet, and one response
    /// carrying all of it outgrows the gRPC receive limit.
    async fn topology_edges(&self) -> Result<Vec<EdgeEndpoints>> {
        let url = self.dgraph_url.as_deref().ok_or_else(|| {
            CorrelationEngineError::Hydration("topology edges require DGRAPH_URL".into())
        })?;
        let kinds = TOPOLOGY_EDGE_KINDS.map(|(label, _kind)| label);
        let client = TopologyClient::connect(url)
            .await
            .map_err(|e| CorrelationEngineError::Hydration(format!("dgraph connect: {e}")))?;
        client
            .query_edge_endpoints(&kinds)
            .await
            .map_err(|e| CorrelationEngineError::Hydration(format!("topology edges: {e}")))
    }

    /// Run an SRQL query and return its result rows, surfacing engine-side errors.
    async fn query(&self, srql_query: &str) -> Result<Vec<serde_json::Value>> {
        let request = QueryRequest {
            query: srql_query.to_string(),
            limit: Some(self.max_rows),
            cursor: None,
            direction: QueryDirection::default(),
            mode: None,
            permitted_signals: None,
        };

        let response =
            self.srql.query.execute_query(request).await.map_err(|e| {
                CorrelationEngineError::Hydration(format!("query '{srql_query}': {e}"))
            })?;

        if let Some(error) = response.error {
            return Err(CorrelationEngineError::Hydration(format!(
                "query '{srql_query}' returned error: {error}"
            )));
        }

        Ok(response.results)
    }
}

fn reconcile_hydrated_context(
    context: &mut Context,
    devices: Vec<Device>,
    services: Vec<Service>,
    edges: Vec<TopologyEdge>,
) {
    context.devices = devices;
    context.services = services;
    context.edges = edges;
    // Preserve live-managed collections. They are updated by NATS subscribers
    // and do not currently have an SRQL source in refresh().
}

#[async_trait]
impl ContextStore for ContextHydrator {
    async fn current_context(&self) -> Result<Context> {
        // The shared Context is seeded by `refresh` and kept current by the live
        // `signals.state.>` subscriber; hand the reasoner a clone under a read lock.
        Ok(self.ctx.read().await.clone())
    }
}

/// Map an SRQL `devices` row to a [`Device`], enforcing canonical-id discipline.
fn map_device(row: &serde_json::Value) -> Option<Device> {
    let uid = row.get("uid").and_then(|v| v.as_str())?.to_string();
    if !uid.starts_with("sr:") {
        // The engine consumes one canonical ID space; never fork it.
        warn!(uid = %uid, "skipping device with non-canonical id");
        return None;
    }

    Some(Device {
        uid,
        is_available: row.get("is_available").and_then(|v| v.as_bool()),
        is_managed: row.get("is_managed").and_then(|v| v.as_bool()),
        risk_score: row.get("risk_score").and_then(|v| v.as_i64()),
        gateway_id: row
            .get("gateway_id")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        pkg_severity: row.get("pkg_worst_severity").and_then(|v| v.as_i64()),
        // gateway_class / flap_count / observation_expected populated as their
        // feeds land (task 1.2b / topology graph projection).
        ..Default::default()
    })
}

/// Map an SRQL `services` row to a [`Service`] keyed by composite identity
/// (`agent_id:service_type:service_name`, Decision 2).
fn map_service(row: &serde_json::Value) -> Option<Service> {
    let agent = row
        .get("agent_id")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let service_type = row
        .get("service_type")
        .and_then(|v| v.as_str())
        .unwrap_or("unknown");
    let service_name = row.get("service_name").and_then(|v| v.as_str())?;

    Some(Service {
        id: format!("{agent}:{service_type}:{service_name}"),
        available: row.get("available").and_then(|v| v.as_bool()),
    })
}

/// Map a topology edge label (`topo.kind`) to the engine's [`EdgeKind`]. Unknown labels
/// are dropped (coverage broadens as new edge kinds are projected).
fn edge_kind_from_label(label: &str) -> Option<EdgeKind> {
    TOPOLOGY_EDGE_KINDS
        .iter()
        .find(|(known, _kind)| *known == label)
        .map(|(_known, kind)| *kind)
}

/// Project stored edges into deduplicated topology edges, enforcing
/// canonical-id discipline (both endpoints must be `sr:`-keyed).
///
/// Dedup keys on the resolved [`EdgeKind`], not the label: several labels
/// collapse onto one kind, and one link labelled both `CONNECTS_TO` and
/// `CANONICAL_TOPOLOGY` would otherwise become two parallel edges, which hides
/// it from bridge detection.
fn parse_topology_edges(rows: &[EdgeEndpoints]) -> Vec<TopologyEdge> {
    let mut seen: HashSet<(&str, &str, EdgeKind)> = HashSet::new();
    let mut edges = Vec::new();
    for row in rows {
        let Some(kind) = edge_kind_from_label(&row.kind) else {
            continue;
        };
        if !row.source.starts_with("sr:") || !row.target.starts_with("sr:") {
            // The engine consumes one canonical ID space; never fork it.
            continue;
        }
        if seen.insert((row.source.as_str(), row.target.as_str(), kind)) {
            edges.push(TopologyEdge::new(
                row.source.as_str(),
                row.target.as_str(),
                kind,
            ));
        }
    }
    edges
}

#[cfg(test)]
mod tests {
    use super::{
        edge_kind_from_label, map_device, map_service, parse_topology_edges,
        reconcile_hydrated_context,
    };
    use crate::domain_model::{
        AttributedFlow, BgpRoute, Context, Device, EdgeKind, InterfaceLink, OperatorRule, Service,
        TopologyEdge,
    };
    use dgraph_topology::EdgeEndpoints;
    use serde_json::json;

    #[test]
    fn maps_a_canonical_device_row() {
        let device = map_device(&json!({
            "uid": "sr:device:abc",
            "is_available": true,
            "is_managed": false,
            "risk_score": 42
        }))
        .expect("device");

        assert_eq!(device.uid, "sr:device:abc");
        assert_eq!(device.is_available, Some(true));
        assert_eq!(device.is_managed, Some(false));
        assert_eq!(device.risk_score, Some(42));
    }

    #[test]
    fn skips_non_canonical_device_id() {
        assert!(map_device(&json!({ "uid": "device-1" })).is_none());
        assert!(map_device(&json!({ "is_available": true })).is_none());
    }

    #[test]
    fn maps_service_to_composite_identity() {
        let service = map_service(&json!({
            "agent_id": "agent-1",
            "service_type": "grpc",
            "service_name": "datasvc",
            "available": false
        }))
        .expect("service");

        assert_eq!(service.id, "agent-1:grpc:datasvc");
        assert_eq!(service.available, Some(false));
    }

    #[test]
    fn maps_edge_labels_to_kinds() {
        assert_eq!(
            edge_kind_from_label("CONNECTS_TO"),
            Some(EdgeKind::ConnectsTo)
        );
        assert_eq!(
            edge_kind_from_label("MANAGED_BY"),
            Some(EdgeKind::ManagedBy)
        );
        assert_eq!(edge_kind_from_label("CONTAINS"), Some(EdgeKind::Contains));
        assert_eq!(edge_kind_from_label("BACKED_BY"), Some(EdgeKind::BackedBy));
        assert_eq!(
            edge_kind_from_label("DEPENDS_ON"),
            Some(EdgeKind::DependsOn)
        );
        assert_eq!(
            edge_kind_from_label("CANONICAL_TOPOLOGY"),
            Some(EdgeKind::ConnectsTo)
        );
        assert_eq!(
            edge_kind_from_label("LOGICAL_PEER"),
            Some(EdgeKind::ConnectsTo)
        );
        assert_eq!(edge_kind_from_label("HAS_INTERFACE"), None);
    }

    fn graph_edge(start: &str, end: &str, label: &str) -> EdgeEndpoints {
        EdgeEndpoints {
            kind: label.to_string(),
            source: start.to_string(),
            target: end.to_string(),
        }
    }

    #[test]
    fn parses_canonical_topology_edges_and_dedupes() {
        let results = vec![
            graph_edge("sr:device:a", "sr:device:b", "CONNECTS_TO"),
            // duplicate row -> deduped
            graph_edge("sr:device:a", "sr:device:b", "CONNECTS_TO"),
            graph_edge("sr:device:child", "sr:device:mgr", "MANAGED_BY"),
        ];
        let edges = parse_topology_edges(&results);
        assert_eq!(edges.len(), 2);
        assert!(edges.iter().any(|e| e.src == "sr:device:a"
            && e.dst == "sr:device:b"
            && e.kind == EdgeKind::ConnectsTo));
        assert!(edges.iter().any(|e| e.kind == EdgeKind::ManagedBy));
    }

    #[test]
    fn labels_that_share_a_kind_do_not_become_parallel_edges() {
        // One physical link is written twice in Dgraph: CONNECTS_TO by the
        // mapper and CANONICAL_TOPOLOGY by the canonical rebuild. Both map to
        // EdgeKind::ConnectsTo, and a second copy would give the link a
        // parallel sibling, which stops bridge detection reporting it.
        let results = vec![
            graph_edge("sr:device:a", "sr:device:b", "CONNECTS_TO"),
            graph_edge("sr:device:a", "sr:device:b", "CANONICAL_TOPOLOGY"),
            graph_edge("sr:device:a", "sr:device:b", "LOGICAL_PEER"),
        ];
        let edges = parse_topology_edges(&results);
        assert_eq!(
            edges.len(),
            1,
            "three labels collapsing onto one kind must yield one edge, got {edges:?}"
        );
        assert_eq!(edges[0].kind, EdgeKind::ConnectsTo);
    }

    #[test]
    fn hydrated_contains_row_keeps_host_as_source() {
        let results = vec![graph_edge("sr:host-1", "sr:guest-1", "CONTAINS")];
        let edges = parse_topology_edges(&results);
        assert_eq!(edges.len(), 1, "got {edges:?}");
        assert_eq!(edges[0].src, "sr:host-1");
        assert_eq!(edges[0].dst, "sr:guest-1");
        assert_eq!(edges[0].kind, EdgeKind::Contains);
    }

    #[test]
    fn parse_topology_edges_skips_non_canonical_and_unknown_labels() {
        let results = vec![
            graph_edge("device-1", "sr:device:b", "CONNECTS_TO"), // non-canonical src
            graph_edge("sr:device:a", "sr:device:b", "HAS_INTERFACE"), // unmodeled label
        ];
        assert!(parse_topology_edges(&results).is_empty());
    }

    #[test]
    fn reconcile_hydrated_context_preserves_live_managed_collections() {
        let mut context = Context {
            devices: vec![Device {
                uid: "sr:device:old".to_string(),
                is_available: Some(false),
                ..Default::default()
            }],
            services: vec![Service {
                id: "agent:old:service".to_string(),
                available: Some(false),
            }],
            edges: vec![TopologyEdge::new(
                "sr:device:old",
                "sr:device:other",
                EdgeKind::ConnectsTo,
            )],
            links: vec![InterfaceLink {
                src: "sr:device:a".to_string(),
                dst: "sr:device:b".to_string(),
                flow_bps: Some(10),
                capacity_bps: Some(100),
            }],
            flows: vec![AttributedFlow {
                src_uid: "sr:device:a".to_string(),
                dst_uid: "sr:device:b".to_string(),
                src_risk_score: Some(4),
            }],
            bgp_routes: vec![BgpRoute {
                prefix: "10.0.0.0/24".to_string(),
                withdrawn: true,
                origin_uid: "sr:device:router".to_string(),
                downstream_uids: vec!["sr:device:leaf".to_string()],
            }],
            operator_rules: vec![OperatorRule {
                rule_id: "causal-anomaly:sr:device:a:cpu".to_string(),
                entity_uid: "sr:device:a".to_string(),
                condition_met: true,
                description: "anomaly evidence".to_string(),
                last_updated_unix_ms: 1_000,
            }],
        };

        reconcile_hydrated_context(
            &mut context,
            vec![Device {
                uid: "sr:device:new".to_string(),
                is_available: Some(true),
                ..Default::default()
            }],
            vec![Service {
                id: "agent:new:service".to_string(),
                available: Some(true),
            }],
            vec![TopologyEdge::new(
                "sr:device:new",
                "sr:device:peer",
                EdgeKind::ManagedBy,
            )],
        );

        assert_eq!(context.devices[0].uid, "sr:device:new");
        assert_eq!(context.services[0].id, "agent:new:service");
        assert_eq!(context.edges[0].kind, EdgeKind::ManagedBy);
        assert_eq!(context.links.len(), 1);
        assert_eq!(context.flows.len(), 1);
        assert_eq!(context.bgp_routes.len(), 1);
        assert_eq!(context.operator_rules.len(), 1);
        assert_eq!(context.operator_rules[0].description, "anomaly evidence");
    }
}
