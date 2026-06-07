//! Context hydration — the seam between data acquisition and reasoning.
//!
//! [`ContextStore`] is the trait the reasoner uses to obtain the current
//! `Context`. In V1 it is an in-process direct call; the trait preserves a
//! future hydrator/reasoner split (a gRPC/NATS implementation) without a
//! rewrite (add-causal-engine design.md, the `ContextStore` decision).

use std::collections::HashSet;
use std::sync::Arc;

use async_trait::async_trait;
use srql::config::AppConfig;
use srql::{EmbeddedSrql, QueryDirection, QueryRequest};
use tokio::sync::RwLock;
use tracing::warn;

use crate::domain_model::{Context, Device, EdgeKind, Service, TopologyEdge};
use crate::error::{CausalEngineError, Result};
use crate::snapshot::SnapshotStore;

/// Upper bound on rows pulled per entity in a single current-state snapshot.
const DEFAULT_MAX_HYDRATION_ROWS: i64 = 50_000;

/// SRQL `graph_cypher` query projecting the topology edges the causaloids reason
/// over (C1/C2/C4/C5/C5b/C7/C9/C10). Read-only `MATCH`/`RETURN`; the AGE `Device`
/// vertex keys on the canonical `id` property (`ocsf_devices.uid`), so `a.id`/
/// `b.id` are canonical `sr:` ids. The returned `{start_id,end_id,label}` object
/// is wrapped by `graph_cypher` into `{nodes,edges}` (see `parse_topology_edges`).
const TOPOLOGY_EDGES_QUERY: &str = "in:graph_cypher cypher:\"MATCH (a)-[r]->(b) WHERE type(r) IN ['CONNECTS_TO','MANAGED_BY','CONTAINS','BACKED_BY','DEPENDS_ON'] RETURN {start_id: a.id, end_id: b.id, label: type(r)} AS result\"";

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
/// TODO(1.2b+): a subscriber for the existing causal subjects
/// (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF), and
/// broaden coverage to interfaces, agents, gateways, flows, virtualization, BGP,
/// MTR, and health transitions. Never consume TimescaleDB hypertable CDC (those
/// are queried on demand here).
pub struct ContextHydrator {
    srql: EmbeddedSrql,
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
            .map_err(|e| CausalEngineError::Hydration(format!("srql config: {e}")))?;
        let srql = EmbeddedSrql::new(config)
            .await
            .map_err(|e| CausalEngineError::Hydration(format!("embedded srql: {e}")))?;

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
            ctx: Arc::new(RwLock::new(restored)),
            snapshot,
            max_rows: DEFAULT_MAX_HYDRATION_ROWS,
        };

        if let Err(err) = hydrator.refresh().await {
            warn!(error = %err, "initial context refresh failed; serving restored snapshot");
        }

        Ok(hydrator)
    }

    /// Re-snapshot current state from CNPG, replace the shared `Context`, and
    /// persist it to disk. Called periodically to reconcile and pick up new
    /// entities; live `signals.state.>` deltas keep the `Context` current between.
    pub async fn refresh(&self) -> Result<()> {
        let devices = self.query("in:devices").await?;
        let services = self.query("in:services").await?;
        // Topology edges are best-effort: an AGE projection hiccup must not abort
        // the whole refresh — the engine still reasons from the snapshot + the
        // live state-change deltas, just without the structural causaloids this
        // tick.
        let edges = match self.query(TOPOLOGY_EDGES_QUERY).await {
            Ok(rows) => parse_topology_edges(&rows),
            Err(err) => {
                warn!(error = %err, "topology edge projection failed; reasoning without edges this tick");
                Vec::new()
            }
        };
        let context = Context {
            devices: devices.iter().filter_map(map_device).collect(),
            services: services.iter().filter_map(map_service).collect(),
            edges,
            // TODO(1.2b): populate links (interface flow/capacity), flows
            // (attributed_flow), bgp_routes, and operator_rules (stateful_alert_
            // rules) via on-demand SRQL queries as those feeds come online; the
            // saturation/BGP/operator-rule causaloids no-op on empty collections.
            ..Default::default()
        };
        *self.ctx.write().await = context.clone();
        if let Err(err) = self.snapshot.save(&context) {
            warn!(error = %err, "context snapshot save failed");
        }
        Ok(())
    }

    /// A handle to the shared `Context` for the live state-change subscriber.
    pub fn shared_context(&self) -> Arc<RwLock<Context>> {
        Arc::clone(&self.ctx)
    }

    /// Run an SRQL query and return its result rows, surfacing engine-side errors.
    async fn query(&self, srql_query: &str) -> Result<Vec<serde_json::Value>> {
        let request = QueryRequest {
            query: srql_query.to_string(),
            limit: Some(self.max_rows),
            cursor: None,
            direction: QueryDirection::default(),
            mode: None,
        };

        let response = self
            .srql
            .query
            .execute_query(request)
            .await
            .map_err(|e| CausalEngineError::Hydration(format!("query '{srql_query}': {e}")))?;

        if let Some(error) = response.error {
            return Err(CausalEngineError::Hydration(format!(
                "query '{srql_query}' returned error: {error}"
            )));
        }

        Ok(response.results)
    }
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
        // feeds land (task 1.2b / graph_cypher projection).
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

/// Map an AGE relationship label to the engine's [`EdgeKind`]. Unknown labels
/// are dropped (coverage broadens as new edge kinds are projected).
fn edge_kind_from_label(label: &str) -> Option<EdgeKind> {
    match label {
        "CONNECTS_TO" => Some(EdgeKind::ConnectsTo),
        "MANAGED_BY" => Some(EdgeKind::ManagedBy),
        "CONTAINS" => Some(EdgeKind::Contains),
        "BACKED_BY" => Some(EdgeKind::BackedBy),
        "DEPENDS_ON" => Some(EdgeKind::DependsOn),
        _ => None,
    }
}

/// Project the `graph_cypher` result rows (each `{nodes,edges}`, with every
/// `edge` carrying `start_id`/`end_id`/`label`) into deduplicated topology
/// edges, enforcing canonical-id discipline (both endpoints must be `sr:`-keyed).
fn parse_topology_edges(results: &[serde_json::Value]) -> Vec<TopologyEdge> {
    let mut seen: HashSet<(String, String, String)> = HashSet::new();
    let mut edges = Vec::new();
    for result in results {
        let Some(edge_rows) = result.get("edges").and_then(|e| e.as_array()) else {
            continue;
        };
        for edge in edge_rows {
            let (Some(src), Some(dst), Some(label)) = (
                edge.get("start_id").and_then(|v| v.as_str()),
                edge.get("end_id").and_then(|v| v.as_str()),
                edge.get("label").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            let Some(kind) = edge_kind_from_label(label) else {
                continue;
            };
            if !src.starts_with("sr:") || !dst.starts_with("sr:") {
                // The engine consumes one canonical ID space; never fork it.
                continue;
            }
            if seen.insert((src.to_string(), dst.to_string(), label.to_string())) {
                edges.push(TopologyEdge::new(src, dst, kind));
            }
        }
    }
    edges
}

#[cfg(test)]
mod tests {
    use super::{edge_kind_from_label, map_device, map_service, parse_topology_edges};
    use crate::domain_model::EdgeKind;
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
        assert_eq!(edge_kind_from_label("HAS_INTERFACE"), None);
    }

    /// Mirror the `graph_cypher` wrapper shape: each row is `{nodes, edges}` and
    /// every edge carries `start_id`/`end_id`/`label`.
    fn cypher_edge(start: &str, end: &str, label: &str) -> serde_json::Value {
        json!({
            "nodes": [{ "id": start, "label": start }, { "id": end, "label": end }],
            "edges": [{ "start_id": start, "end_id": end, "label": label }]
        })
    }

    #[test]
    fn parses_canonical_topology_edges_and_dedupes() {
        let results = vec![
            cypher_edge("sr:device:a", "sr:device:b", "CONNECTS_TO"),
            // duplicate row -> deduped
            cypher_edge("sr:device:a", "sr:device:b", "CONNECTS_TO"),
            cypher_edge("sr:device:child", "sr:device:mgr", "MANAGED_BY"),
        ];
        let edges = parse_topology_edges(&results);
        assert_eq!(edges.len(), 2);
        assert!(edges.iter().any(|e| e.src == "sr:device:a"
            && e.dst == "sr:device:b"
            && e.kind == EdgeKind::ConnectsTo));
        assert!(edges.iter().any(|e| e.kind == EdgeKind::ManagedBy));
    }

    #[test]
    fn parse_topology_edges_skips_non_canonical_and_unknown_labels() {
        let results = vec![
            cypher_edge("device-1", "sr:device:b", "CONNECTS_TO"), // non-canonical src
            cypher_edge("sr:device:a", "sr:device:b", "HAS_INTERFACE"), // unmodeled label
        ];
        assert!(parse_topology_edges(&results).is_empty());
    }
}
