//! Context hydration — the seam between data acquisition and reasoning.
//!
//! [`ContextStore`] is the trait the reasoner uses to obtain the current
//! `Context`. In V1 it is an in-process direct call; the trait preserves a
//! future hydrator/reasoner split (a gRPC/NATS implementation) without a
//! rewrite (add-causal-engine design.md, the `ContextStore` decision).

use async_trait::async_trait;
use srql::config::AppConfig;
use srql::{EmbeddedSrql, QueryDirection, QueryRequest};
use tracing::warn;

use crate::domain_model::{Context, Device, Service};
use crate::error::{CausalEngineError, Result};

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
/// Feed 1 (current-state snapshot) is implemented here via `EmbeddedSrql` over
/// CNPG. TODO(1.2b): add the live-delta feeds and merge them into the `Context`:
///   - a JetStream subscriber for the existing causal subjects
///     (`signals.causal.>`, `arancini.updates.>`, `siem.events.>`, zen OCSF);
///   - a JetStream subscriber for the app-level `signals.state.<table>`
///     state-change feed (Phase 0, Decision 1).
///
/// Also broaden coverage to interfaces, agents, gateways, flows, virtualization,
/// BGP, MTR, and health transitions. Never consume TimescaleDB hypertable CDC
/// (those are queried on demand here).
pub struct ContextHydrator {
    srql: EmbeddedSrql,
    max_rows: i64,
}

impl ContextHydrator {
    /// Open a CNPG pool via `EmbeddedSrql`, using srql's `AppConfig`
    /// (`SRQL_*` / `DATABASE_URL` env) shared across the deployment.
    pub async fn connect() -> Result<Self> {
        let config = AppConfig::from_env()
            .map_err(|e| CausalEngineError::Hydration(format!("srql config: {e}")))?;
        let srql = EmbeddedSrql::new(config)
            .await
            .map_err(|e| CausalEngineError::Hydration(format!("embedded srql: {e}")))?;
        Ok(Self {
            srql,
            max_rows: DEFAULT_MAX_HYDRATION_ROWS,
        })
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
        // Feed 1: current-state snapshot via EmbeddedSrql. TODO(1.2b): merge live
        // JetStream + signals.state.<table> deltas and broaden entity coverage.
        let devices = self.query("in:devices").await?;
        let services = self.query("in:services").await?;

        Ok(Context {
            devices: devices.iter().filter_map(map_device).collect(),
            services: services.iter().filter_map(map_service).collect(),
        })
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
