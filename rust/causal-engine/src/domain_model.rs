//! V1 domain model — Rust types for the entities and relationships the engine
//! reasons over. These are projected into the DeepCausality `Context` by the
//! hydrator. Identity discipline (add-causal-engine): every entity is keyed by
//! the canonical `sr:`-prefixed id reused from `RuntimeGraph` — the engine never
//! invents a parallel ID space (`ocsf_devices.uid == AGE Device.id ==
//! ocsf_events.device.uid`).

use serde::{Deserialize, Serialize};

/// Canonical, `sr:`-prefixed entity identifier.
pub type EntityId = String;

/// The hydrated world-state the reasoner evaluates each tick.
///
/// TODO(1.2): populate from `EmbeddedSrql` (current state + on-demand
/// continuous-aggregate queries + AGE topology) merged with JetStream and
/// `signals.state.<table>` deltas. Extend with interfaces, agents, gateways,
/// flows, virtualization, BGP, MTR, and health-transition state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Context {
    /// Devices keyed by canonical `uid`.
    pub devices: Vec<Device>,
    /// Services (composite identity per Decision 2).
    pub services: Vec<Service>,
}

/// A device (from `ocsf_devices` + AGE `Device` vertex).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    /// Canonical `sr:`-prefixed uid.
    pub uid: EntityId,
    /// Binary availability (`None` when unknown / not yet observed).
    pub is_available: Option<bool>,
    /// Whether the device is managed.
    pub is_managed: Option<bool>,
    /// MAX-wins device risk from `DeviceRiskReducer` (composed into C5/C7/C10).
    pub risk_score: Option<i64>,
    // TODO(1.5/1.8): bounded `pkg_*` risk-summary scalars projected onto the
    // Device vertex (pkg_worst_severity / pkg_critical_count / pkg_kev_count /
    // pkg_has_unpatched_rce).
}

/// A service (from `service_status` / `service_state`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Service {
    /// Composite service identity (`agent_id:service_type:service_name`).
    pub id: EntityId,
    /// Availability (`None` when unknown).
    pub available: Option<bool>,
}
