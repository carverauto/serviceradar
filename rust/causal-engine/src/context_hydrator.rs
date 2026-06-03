//! Context hydration — the seam between data acquisition and reasoning.
//!
//! [`ContextStore`] is the trait the reasoner uses to obtain the current
//! `Context`. In V1 it is an in-process direct call; the trait preserves a
//! future hydrator/reasoner split (a gRPC/NATS implementation) without a
//! rewrite (add-causal-engine design.md, the `ContextStore` decision).

use std::sync::Arc;

use async_trait::async_trait;
use srql::config::AppConfig;
use srql::{EmbeddedSrql, QueryDirection, QueryRequest};
use tokio::sync::RwLock;
use tracing::warn;

use crate::domain_model::{Context, Device, Service};
use crate::error::{CausalEngineError, Result};
use crate::snapshot::SnapshotStore;

/// Upper bound on rows pulled per entity in a single current-state snapshot.
const DEFAULT_MAX_HYDRATION_ROWS: i64 = 50_000;

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
        let context = Context {
            devices: devices.iter().filter_map(map_device).collect(),
            services: services.iter().filter_map(map_service).collect(),
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

#[cfg(test)]
mod tests {
    use super::{map_device, map_service};
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
}
